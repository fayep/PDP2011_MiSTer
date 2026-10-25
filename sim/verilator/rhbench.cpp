// sim/verilator/rhbench.cpp -- Verilator harness for unibus_vl_rh: the main.cpp machine (11/70,
// console KL11, KW11-L, RAM below the Unibus window) plus an RH70/RP06 whose hps_io disk slot is
// served here the way MiSTer Main serves it (seen in Main's sdtrace): Main notices rd or wr at its
// poll, takes the request (lba) then and serves it later whatever rd/wr do meanwhile -- raises ack,
// streams the 256 words (read: sd_buff_wr into the controller; write: reads sd_buff_din), drops
// ack. The poll latency and the service time are random (--seed, --pick, --serve), so a sweep
// meets the controller's handshake at every phase. Disk contents: word i of block n = n ^ (i*0401).
// Stops on HALT (prints the console), PASS/FAIL text, QUIET, or the cycle budget.
//
//   vsim_rh --mem build/rhint.mem --pc 2000 [--budget N] [--seed S] [--pick MIN:MAX] [--serve MIN:MAX]
#include "Vunibus_vl_rh.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <random>
#include <string>
#include <vector>
#include <chrono>

static const uint32_t RAM_WORDS = 1966080;                  // addresses below 17000000 (22-bit)

int main(int argc, char** argv) {
    std::string mem, pass = "END PASS", fail = "FAIL";
    uint32_t pc = 02000, bitc = 216;
    uint64_t budget = 400000000, quiet = 50000000, seed = 1;
    uint32_t pick_lo = 20, pick_hi = 3000, serve_lo = 10, serve_hi = 400;
    auto range = [](const std::string& v, uint32_t& lo, uint32_t& hi) {
        size_t c = v.find(':'); lo = strtoul(v.c_str(), nullptr, 10); hi = c == std::string::npos ? lo : strtoul(v.c_str() + c + 1, nullptr, 10);
    };
    for (int i = 1; i + 1 < argc; i += 2) {
        std::string k = argv[i], v = argv[i + 1];
        if (k == "--mem") mem = v;
        else if (k == "--pc") pc = strtoul(v.c_str(), nullptr, 8);
        else if (k == "--budget") budget = strtoull(v.c_str(), nullptr, 10);
        else if (k == "--quiet") quiet = strtoull(v.c_str(), nullptr, 10);
        else if (k == "--seed") seed = strtoull(v.c_str(), nullptr, 10);
        else if (k == "--pick") range(v, pick_lo, pick_hi);
        else if (k == "--serve") range(v, serve_lo, serve_hi);
        else if (k == "--pass") pass = v;
        else if (k == "--fail") fail = v;
        else { fprintf(stderr, "vsim_rh: unknown option %s\n", k.c_str()); return 2; }
    }
    std::vector<uint16_t> ram(RAM_WORDS, 0);
    {
        std::ifstream f(mem);
        if (!f) { fprintf(stderr, "vsim_rh: cannot open %s\n", mem.c_str()); return 2; }
        long w, d;
        while (f >> w >> d) if (w >= 0 && w < (long)RAM_WORDS) ram[w] = (uint16_t)(d & 0xffff);
    }
    std::mt19937_64 rng(seed);
    auto rnd = [&](uint32_t lo, uint32_t hi) { return lo + (uint32_t)(rng() % (uint64_t)(hi - lo + 1)); };

    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    auto u = std::make_unique<Vunibus_vl_rh>(ctx.get());
    u->init_r7 = pc; u->cons_sw = 0; u->rx0 = 1; u->dati = 0; u->addr_match = 0;
    u->rh_sd_ack = 0; u->sd_buff_addr = 0; u->sd_buff_dout = 0; u->sd_buff_wr = 0;
    u->clk = 0; u->clk50mhz = 0; u->reset = 1;

    uint16_t dati_hold = 0;
    auto bus = [&]() {
        uint32_t a = u->addr;
        bool match = ((a >> 18) & 0xf) != 0xf;
        u->addr_match = match;
        uint32_t widx = match ? (a >> 1) : 0;
        u->dati = (match && u->control_dati && widx < RAM_WORDS) ? ram[widx] : dati_hold;
        u->eval();
    };

    // Main's side of the disk slot
    enum { H_IDLE, H_PICKED, H_XFER, H_DROP } hs = H_IDLE;
    uint64_t h_at = 0; int h_op = 0; uint32_t h_lba = 0; int h_word = 0;
    uint64_t n_rd = 0, n_wr = 0;

    std::string cons, line;
    uint64_t cyc = 0, last_out = 0;
    bool saw_run = false;
    uint64_t halt_at = 0, run_lo = 0;
    struct bt { uint64_t c; uint32_t a; uint16_t d; bool w; } btr[64] = {}; uint32_t bti = 0;
    int rx_state = -1; uint64_t rx_next = 0; int rx_bit = 0; uint8_t rx_acc = 0; int tx_prev = 1;
    auto t0 = std::chrono::steady_clock::now();
    const char* verdict = "TIMEOUT";
    for (cyc = 0; cyc < budget + 20; cyc++) {
        if (cyc == 10) u->reset = 0;

        // Main: inputs for this rising edge
        u->sd_buff_wr = 0;
        switch (hs) {
        case H_IDLE:
            if (!u->reset && (u->rh_sd_rd || u->rh_sd_wr)) {        // seen at a poll: taken now
                h_op = u->rh_sd_rd ? 1 : 2; h_lba = u->rh_sd_lba;
                hs = H_PICKED; h_at = cyc + rnd(pick_lo, pick_hi);
            }
            break;
        case H_PICKED:                                              // the read/seek of the image file
            if (cyc >= h_at) { u->rh_sd_ack = 1; h_word = 0; hs = H_XFER; h_at = cyc + 2; }
            break;
        case H_XFER:
            if (cyc < h_at) break;
            if (h_word < 256) {
                u->sd_buff_addr = h_word;
                if (h_op == 1) { u->sd_buff_dout = (uint16_t)(h_lba ^ (h_word * 0401)); u->sd_buff_wr = 1; }
                h_word++;
            } else { hs = H_DROP; h_at = cyc + rnd(serve_lo, serve_hi); }
            break;
        case H_DROP:
            if (cyc >= h_at) { u->rh_sd_ack = 0; (h_op == 1 ? n_rd : n_wr)++; hs = H_IDLE; }
            break;
        }

        bus();
        uint32_t a = u->addr;
        bool match = ((a >> 18) & 0xf) != 0xf;
        uint32_t widx = match ? (a >> 1) : 0;
        if (match && u->control_dati && widx < RAM_WORDS) dati_hold = ram[widx];
        {   // the last 64 bus cycles, printed at a HALT
            static uint32_t lastkey = 0xffffffff;
            if (u->control_dati || u->control_dato) {
                uint32_t key = (a << 2) | (u->control_dato << 1) | u->control_dati;
                if (key != lastkey) { btr[bti++ & 63] = { cyc, a, (uint16_t)(u->control_dato ? u->dato : (match && widx < RAM_WORDS ? ram[widx] : 0)), (bool)u->control_dato }; }
                lastkey = key;
            } else lastkey = 0xffffffff;
        }
        if (match && u->control_dato && widx < RAM_WORDS) {
            uint16_t d = u->dato;
            if (!u->control_datob) ram[widx] = d;
            else if (!(a & 1)) ram[widx] = (ram[widx] & 0xff00) | (d & 0x00ff);
            else ram[widx] = (ram[widx] & 0x00ff) | (d & 0xff00);
        }
        u->clk = 1; u->clk50mhz = 1; u->eval(); bus();
        u->clk = 0; u->clk50mhz = 0; u->eval(); bus();

        int tx = u->tx0;
        if (rx_state < 0) {
            if (tx_prev == 1 && tx == 0 && !u->reset) { rx_state = 0; rx_next = cyc + (bitc * 3) / 2; rx_bit = 0; rx_acc = 0; }
        } else if (cyc >= rx_next) {
            if (tx) rx_acc |= (1 << rx_bit);
            if (++rx_bit == 8) {
                char ch = (char)rx_acc;
                rx_state = -1; last_out = cyc;
                cons.push_back(ch); if (cons.size() > 4096) cons.erase(0, cons.size() - 4096);
                if (ch == '\r' || ch == '\n') { if (!line.empty()) printf("KL11: %s\n", line.c_str()); fflush(stdout); line.clear(); }
                else if (ch != 0 && ch != (char)0x7f && ch != (char)0xff) line.push_back(ch);
                auto has = [&](const std::string& n) { return !n.empty() && cons.find(n) != std::string::npos; };
                if (has(pass)) { verdict = "PASS"; break; }
                if (has(fail)) { verdict = "FAIL"; break; }
            } else rx_next = cyc + bitc;
        }
        tx_prev = tx;

        if (u->cons_run) { saw_run = true; run_lo = 0; }                     // RUN drops during DMA too:
        else if (saw_run && ++run_lo > 2000 && !halt_at) { verdict = "HALT"; halt_at = cyc; }   // a halt is RUN off for long
        if (halt_at && cyc - halt_at > 100000) break;
        if (quiet && cyc > 10 && cyc - last_out >= quiet) { verdict = "QUIET"; break; }
        if (cyc >= budget) break;
    }
    if (!line.empty()) printf("KL11: %s\n", line.c_str());
    if (halt_at) for (uint32_t k = bti > 64 ? bti - 64 : 0; k < bti; k++) { auto& e = btr[k & 63];
        printf("  bus %10llu %c %08o %06o\n", (unsigned long long)e.c, e.w ? 'W' : 'R', e.a, e.d); }
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    printf("vsim_rh %s seed=%llu cycles=%llu reads=%llu writes=%llu in %.1f s wall, %.2f Mcycles/s\n", verdict,
           (unsigned long long)seed, (unsigned long long)cyc, (unsigned long long)n_rd, (unsigned long long)n_wr,
           secs, cyc / secs / 1e6);
    u->final();
    return (strcmp(verdict, "PASS") == 0) ? 0 : 1;
}
