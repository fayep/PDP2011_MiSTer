// pdp_harness: owns /dev/ttyS1 (the PDP2011 core's serial console) so a
// human (tail -f the log) and a scripted debug session (via the control
// socket) can both observe/drive it without fighting over the port.
//
// Usage: pdp_harness [-dev /dev/ttyS1] [-baud 19200] [-log /tmp/pdp_harness/serial.log] [-sock /tmp/pdp_harness.sock] [-tcp :7788]
//
// -tcp (empty by default -- opt in explicitly) additionally listens on a
// TCP port, same protocol, same dispatch/handleConn code as the unix
// socket -- so a session on a DIFFERENT machine can drive the console
// directly (`nc <mister-ip> 7788` or a plain TCP client) instead of
// wrapping every single command in ssh+socat. No auth at all -- this is
// meant for a trusted local lab network (matching the rest of this
// project's own tooling: plain-password SSH, unauthenticated
// /dev/MiSTer_cmd writes), NOT for exposing to the internet.
//
// Control protocol (one line per request over the unix socket or -tcp,
// plain text):
//   send <text>       -- write <text> + CR to the serial TX
//   sendraw <hex>      -- write raw hex-encoded bytes to the serial TX (e.g. control chars)
//   log [n]            -- replies "OK <base64 of the last n bytes (default
//                          2000, capped at the ring buffer size) of raw
//                          serial RX>" -- reading output no longer needs a
//                          separate ssh+tail of the log FILE at all (Faye:
//                          "you still have to ssh in to get the serial
//                          log, is the irony of that lost on you?"),
//                          decode client-side, e.g.:
//                          echo log | nc -w2 host port | cut -d' ' -f2 | base64 -d
//   newlog             -- replies "OK <base64 of everything written since
//                          the last newlog call>" -- a shared cursor
//                          (across all connections), so repeated polling
//                          during an interactive session doesn't have to
//                          re-fetch/re-decode output already seen (Faye:
//                          "maybe you should have made the log command
//                          give you a tail instead of from the top" / "or
//                          just a newlog"). Falls back to returning from
//                          the oldest still-retained byte if the cursor
//                          has fallen behind the ring buffer's own bound.
//   ping               -- replies "pong"
// Every request gets exactly one line back: "OK[ <data>]" or "ERR <message>".
package main

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

func openSerial(path string, baud uint32) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		return nil, err
	}
	fd := int(f.Fd())

	t, err := unix.IoctlGetTermios(fd, unix.TCGETS)
	if err != nil {
		f.Close()
		return nil, err
	}

	// raw mode: no line discipline, no echo, no signal chars, 8N1, no flow control
	t.Iflag &^= unix.IGNBRK | unix.BRKINT | unix.PARMRK | unix.ISTRIP |
		unix.INLCR | unix.IGNCR | unix.ICRNL | unix.IXON | unix.IXOFF
	t.Oflag &^= unix.OPOST
	t.Lflag &^= unix.ECHO | unix.ECHONL | unix.ICANON | unix.ISIG | unix.IEXTEN
	t.Cflag &^= unix.CSIZE | unix.PARENB | unix.CSTOPB | unix.CRTSCTS
	t.Cflag |= unix.CS8 | unix.CREAD | unix.CLOCAL
	t.Cc[unix.VMIN] = 1
	t.Cc[unix.VTIME] = 0

	if err := unix.IoctlSetTermios(fd, unix.TCSETS, t); err != nil {
		f.Close()
		return nil, err
	}

	speed, ok := map[uint32]uint32{
		1200: unix.B1200, 2400: unix.B2400, 4800: unix.B4800,
		9600: unix.B9600, 19200: unix.B19200, 38400: unix.B38400,
		57600: unix.B57600, 115200: unix.B115200,
	}[baud]
	if !ok {
		f.Close()
		return nil, fmt.Errorf("unsupported baud %d", baud)
	}
	// TCSETS reads the baud rate from the CBAUD bits packed into Cflag,
	// not from Ispeed/Ospeed -- those fields only matter with the
	// newer termios2/TCSETS2 API. Setting Ispeed/Ospeed alone (as an
	// earlier version of this code did) is silently ignored by TCSETS,
	// so the port kept whatever rate it already had (confirmed via
	// `stty -F <dev> -a` showing 9600 no matter what -baud was passed).
	t.Cflag = (t.Cflag &^ unix.CBAUD) | speed
	t.Ispeed = speed
	t.Ospeed = speed
	if err := unix.IoctlSetTermios(fd, unix.TCSETS, t); err != nil {
		f.Close()
		return nil, err
	}

	return f, nil
}

// ringBuf: bounded in-memory copy of the last N bytes of raw serial RX,
// so the "log" control command can serve recent output without ever
// touching the log FILE (or needing filesystem/ssh access at all) --
// updated from the same RX goroutine that writes to logFile, so it's
// always exactly the same bytes, just kept in memory too.
type ringBuf struct {
	mu     sync.Mutex
	buf    []byte
	max    int
	total  int64 // cumulative bytes ever written, for newlog's cursor math
	cursor int64 // absolute position of the last "newlog" read (shared across all connections)
}

func newRingBuf(max int) *ringBuf {
	return &ringBuf{max: max}
}

func (r *ringBuf) write(p []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.buf = append(r.buf, p...)
	r.total += int64(len(p))
	if len(r.buf) > r.max {
		r.buf = r.buf[len(r.buf)-r.max:]
	}
}

func (r *ringBuf) tail(n int) []byte {
	r.mu.Lock()
	defer r.mu.Unlock()
	if n <= 0 || n > len(r.buf) {
		n = len(r.buf)
	}
	out := make([]byte, n)
	copy(out, r.buf[len(r.buf)-n:])
	return out
}

// newlog returns only the bytes written since the last newlog call (the
// first call, before the cursor has ever moved, naturally returns
// everything since the harness started -- same as "log" with a huge n),
// then advances the shared cursor. If the cursor has fallen behind what the
// bounded ring buffer still retains (a long gap between polls on a busy
// console), this returns from the oldest still-available byte instead of
// erroring -- some output was truly lost in that case, same tradeoff the
// bounded ring buffer already makes for "log".
func (r *ringBuf) newlog() []byte {
	r.mu.Lock()
	defer r.mu.Unlock()
	start := r.cursor
	oldest := r.total - int64(len(r.buf))
	if start < oldest {
		start = oldest
	}
	offset := int(start - oldest)
	out := make([]byte, len(r.buf)-offset)
	copy(out, r.buf[offset:])
	r.cursor = r.total
	return out
}

func main() {
	dev := flag.String("dev", "/dev/ttyS1", "serial device")
	baud := flag.Uint("baud", 19200, "baud rate")
	logPath := flag.String("log", "/tmp/pdp_harness/serial.log", "raw serial log (tail -f this)")
	sockPath := flag.String("sock", "/tmp/pdp_harness.sock", "control socket path")
	tcpAddr := flag.String("tcp", "", "additionally listen on this TCP address (e.g. :7788) -- empty disables it")
	flag.Parse()

	if err := os.MkdirAll("/tmp/pdp_harness", 0755); err != nil {
		log.Fatalf("mkdir log dir: %v", err)
	}

	serial, err := openSerial(*dev, uint32(*baud))
	if err != nil {
		log.Fatalf("open serial %s: %v", *dev, err)
	}
	defer serial.Close()
	log.Printf("serial: %s @ %d 8N1 raw, no flow control", *dev, *baud)

	logFile, err := os.OpenFile(*logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		log.Fatalf("open log %s: %v", *logPath, err)
	}
	defer logFile.Close()
	fmt.Fprintf(logFile, "\n--- pdp_harness started %s ---\n", time.Now().Format(time.RFC3339))
	log.Printf("logging raw serial RX to %s (tail -f it)", *logPath)

	// 256KiB is comfortably more than any single debug session's worth
	// of "what just happened" -- the log FILE (unbounded, append-only)
	// is still the source of truth for a full-session history; this is
	// only for the "log" control command's own recent-output serving.
	rb := newRingBuf(256 * 1024)

	// RX: copy every byte from serial straight into the log, unbuffered,
	// so `tail -f` shows exactly what a terminal would -- and into the
	// in-memory ring buffer, so the "log" control command can serve
	// recent output without any filesystem access at all.
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := serial.Read(buf)
			if n > 0 {
				logFile.Write(buf[:n])
				logFile.Sync()
				rb.write(buf[:n])
			}
			if err != nil {
				log.Printf("serial read error: %v", err)
				time.Sleep(500 * time.Millisecond)
			}
		}
	}()

	os.Remove(*sockPath)
	l, err := net.Listen("unix", *sockPath)
	if err != nil {
		log.Fatalf("listen %s: %v", *sockPath, err)
	}
	defer l.Close()
	os.Chmod(*sockPath, 0666)
	log.Printf("control socket: %s", *sockPath)

	go acceptLoop(l, serial, logFile, rb)

	if *tcpAddr != "" {
		tl, err := net.Listen("tcp", *tcpAddr)
		if err != nil {
			log.Fatalf("listen tcp %s: %v", *tcpAddr, err)
		}
		defer tl.Close()
		log.Printf("control tcp: %s", *tcpAddr)
		acceptLoop(tl, serial, logFile, rb)
		return
	}

	// no -tcp: block here instead of returning (the unix listener's
	// own acceptLoop above already runs in its own goroutine)
	select {}
}

func acceptLoop(l net.Listener, serial *os.File, logFile *os.File, rb *ringBuf) {
	for {
		conn, err := l.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go handleConn(conn, serial, logFile, rb)
	}
}

func handleConn(conn net.Conn, serial *os.File, logFile *os.File, rb *ringBuf) {
	defer conn.Close()
	scanner := bufio.NewScanner(conn)
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), "\r\n")
		reply := dispatch(line, serial, logFile, rb)
		fmt.Fprintln(conn, reply)
	}
}

func dispatch(line string, serial *os.File, logFile *os.File, rb *ringBuf) string {
	fields := strings.SplitN(line, " ", 2)
	cmd := fields[0]
	var arg string
	if len(fields) > 1 {
		arg = fields[1]
	}

	switch cmd {
	case "ping":
		return "pong"

	case "send":
		fmt.Fprintf(logFile, "\n>>> send %q\n", arg)
		if _, err := serial.Write([]byte(arg + "\r")); err != nil {
			return "ERR " + err.Error()
		}
		return "OK"

	case "sendraw":
		b, err := hex.DecodeString(arg)
		if err != nil {
			return "ERR bad hex: " + err.Error()
		}
		fmt.Fprintf(logFile, "\n>>> sendraw %s\n", arg)
		if _, err := serial.Write(b); err != nil {
			return "ERR " + err.Error()
		}
		return "OK"

	case "log":
		n := 2000
		if arg != "" {
			parsed, err := strconv.Atoi(arg)
			if err != nil {
				return "ERR bad byte count: " + err.Error()
			}
			n = parsed
		}
		return "OK " + base64.StdEncoding.EncodeToString(rb.tail(n))

	case "newlog":
		return "OK " + base64.StdEncoding.EncodeToString(rb.newlog())

	default:
		return "ERR unknown command: " + cmd
	}
}
