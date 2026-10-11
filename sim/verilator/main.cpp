// sim/verilator/main.cpp -- Verilator harness for unibus_vl: the C++ counterpart of tb_xxdp.
//
// Same machine as tb_xxdp: 11/70, console KL11 at 230400 bps, KW11-L, no disks; RAM below the
// Unibus window (1920K words) with the dati hold mister_top has; a .mem image (word-index value
// pairs, as run_xxdp.sh makes) loaded into the low 64K words; the console decoded from tx0.
// Stops like tb_xxdp: PASS / FAIL on console text, HALT when the CPU stops after running,
// QUIET after quiet cycles without console output, TIMEOUT at the cycle budget.
//
//   vsim --mem build/xxdp_EKBEE1.mem --pc 200 [--sw 0] [--budget N] [--quiet N]
//        [--pass TEXT] [--fail TEXT] [--fail2 TEXT] [--bit 216]     (pc and sw in octal)
#include "Vunibus_vl.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>
#include <vector>
#include <chrono>

static const uint32_t RAM_WORDS = 1966080;                  // addresses below 17000000 (22-bit)

int main(int argc, char** argv) {
    std::string mem, pass, fail, fail2;
    uint32_t pc = 0200, sw = 0, bitc = 216;
    uint64_t budget = 24000000, quiet = 5000000;
    for (int i = 1; i + 1 < argc; i += 2) {
        std::string k = argv[i], v = argv[i + 1];
        if (k == "--mem") mem = v;
        else if (k == "--pc") pc = strtoul(v.c_str(), nullptr, 8);
        else if (k == "--sw") sw = strtoul(v.c_str(), nullptr, 8);
        else if (k == "--budget") budget = strtoull(v.c_str(), nullptr, 10);
        else if (k == "--quiet") quiet = strtoull(v.c_str(), nullptr, 10);
        else if (k == "--pass") pass = v;
        else if (k == "--fail") fail = v;
        else if (k == "--fail2") fail2 = v;
        else if (k == "--bit") bitc = strtoul(v.c_str(), nullptr, 10);
        else { fprintf(stderr, "vsim: unknown option %s\n", k.c_str()); return 2; }
    }
    std::vector<uint16_t> ram(RAM_WORDS, 0);
    {
        std::ifstream f(mem);
        if (!f) { fprintf(stderr, "vsim: cannot open %s\n", mem.c_str()); return 2; }
        long w, d;
        while (f >> w >> d) if (w >= 0 && w < 65536) ram[w] = (uint16_t)(d & 0xffff);
    }

    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    auto u = std::make_unique<Vunibus_vl>(ctx.get());
    u->init_r7 = pc; u->cons_sw = sw; u->rx0 = 1; u->dati = 0; u->addr_match = 0;
    u->clk = 0; u->clk50mhz = 0; u->reset = 1;

    uint16_t dati_hold = 0;
    // combinational side of the bus: addr_match and dati follow the core's addr/control outputs
    auto bus = [&]() {
        uint32_t a = u->addr;
        bool match = ((a >> 18) & 0xf) != 0xf;
        u->addr_match = match;
        uint32_t widx = match ? (a >> 1) : 0;
        u->dati = (match && u->control_dati) ? ram[widx] : dati_hold;
        u->eval();
    };

    std::string cons;                   // console text so far (last 4K kept for matching)
    std::string line;
    uint64_t cyc = 0, last_out = 0;
    bool saw_run = false;
    // tx0 decoder: idle high; a falling edge starts a byte, sampled 1.5 bits later, then each bit
    int rx_state = -1; uint64_t rx_next = 0; int rx_bit = 0; uint8_t rx_acc = 0; int tx_prev = 1;

    auto t0 = std::chrono::steady_clock::now();
    const char* verdict = "TIMEOUT";
    for (cyc = 0; cyc < budget + 20; cyc++) {
        if (cyc == 10) u->reset = 0;                         // tb_xxdp: reset low after 205 ns
        // rising edge: the memory write and the dati hold see the values from before the edge
        bus();
        uint32_t a = u->addr;
        bool match = ((a >> 18) & 0xf) != 0xf;
        uint32_t widx = match ? (a >> 1) : 0;
        if (match && u->control_dati) dati_hold = ram[widx];
        static long btrace = getenv("VSIM_BUSTRACE") ? atol(getenv("VSIM_BUSTRACE")) : 0;
        static uint32_t last_key = 0xffffffff;
        if (btrace > 0 && !u->reset && (u->control_dati || u->control_dato)) {   // one line per bus cycle
            uint32_t key = (a << 2) | (u->control_dato << 1) | u->control_dati;
            if (key != last_key) { btrace--;
                if (u->control_dato) printf("W %08o %06o\n", a, u->dato);
                else printf("R %08o %06o\n", a, match ? ram[widx] : 0); }
            last_key = key;
        } else last_key = 0xffffffff;
        if (match && u->control_dato && widx < RAM_WORDS) {
            uint16_t d = u->dato;
            if (!u->control_datob) ram[widx] = d;
            else if (!(a & 1)) ram[widx] = (ram[widx] & 0xff00) | (d & 0x00ff);
            else ram[widx] = (ram[widx] & 0x00ff) | (d & 0xff00);
        }
        u->clk = 1; u->clk50mhz = 1; u->eval(); bus();
        u->clk = 0; u->clk50mhz = 0; u->eval(); bus();

        // console: tx0 on clk50 (same rate and phase as clk here)
        int tx = u->tx0;
        if (rx_state < 0) {
            if (tx_prev == 1 && tx == 0 && !u->reset) { rx_state = 0; rx_next = cyc + (bitc * 3) / 2; rx_bit = 0; rx_acc = 0; }
        } else if (cyc >= rx_next) {
            if (tx) rx_acc |= (1 << rx_bit);
            if (++rx_bit == 8) {
                char ch = (char)rx_acc;
                rx_state = -1; last_out = cyc;
                cons.push_back(ch); if (cons.size() > 4096) cons.erase(0, cons.size() - 4096);
                if (ch == '\r' || ch == '\n') { if (!line.empty()) printf("KL11: %s\n", line.c_str()); line.clear(); }
                else if (ch != 0 && ch != (char)0x7f && ch != (char)0xff) line.push_back(ch);   // XXDP pads with NUL/DEL fill
                auto has = [&](const std::string& n) { return !n.empty() && cons.find(n) != std::string::npos; };
                if (has(pass)) { verdict = "PASS"; break; }
                if (has(fail) || has(fail2)) { verdict = "FAIL"; break; }
            } else rx_next = cyc + bitc;
        }
        tx_prev = tx;

        if (u->cons_run) saw_run = true;
        else if (saw_run) { verdict = "HALT"; break; }
        if (quiet && cyc > 10 && cyc - last_out >= quiet) { verdict = "QUIET"; break; }
        if (cyc >= budget) break;
    }
    if (!line.empty()) printf("KL11: %s\n", line.c_str());
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    printf("vsim %s mem=%s cycles=%llu (%.3f ms simulated) in %.1f s wall, %.2f Mcycles/s\n", verdict,
           mem.c_str(), (unsigned long long)cyc, cyc * 20e-6, secs, cyc / secs / 1e6);
    u->final();
    return (strcmp(verdict, "PASS") == 0) ? 0 : 1;
}
