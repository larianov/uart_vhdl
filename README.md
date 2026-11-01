# UART Core in VHDL

A parameterizable UART transmitter/receiver with TX and RX FIFOs, written in VHDL-2008.
Targets an Intel Cyclone V (Quartus Prime Lite 25.1). The RTL itself is vendor-independent.

> **Authorship.** The UART core (`rtl/`) and the board example (`example/`) were designed
> and written by me. The verification environment in `sim/` (testbenches, UART BFM,
> regression script) was written by an AI assistant.

## Features

- Configurable frame: 1–16 data bits, 1–4 stop bits, parity none / even / odd
- Baud rate set by generics (`freq`, `baud`) with a rounded clock divider
- TX and RX FIFOs (up to 16 words) with full / empty / threshold flags
- RX error detection: parity and framing (stop bit), reported on `rx_uart_err`
- Two-flop synchronizer on the asynchronous `rx_line`
- False-start rejection: the start bit is re-checked at mid-bit
- RX FIFO overwrites the oldest data on overflow

## Verification at a glance

| Configuration | Testbench | Result |
|---|---|---|
| FIFO depth 16, reject on full | `tb_fifo` | PASS |
| FIFO depth 16, overwrite on full | `tb_fifo` | PASS |
| FIFO depth 1, reject on full | `tb_fifo` | PASS |
| FIFO depth 1, overwrite on full | `tb_fifo` | PASS |
| FIFO depth 5, 3-bit words, overwrite | `tb_fifo` | PASS |
| 8N1 @ 115 200 | `tb_uart` | PASS |
| 8E1 @ 115 200 | `tb_uart` | PASS |
| 8O2 @ 115 200 | `tb_uart` | PASS |
| 7E1 @ 115 200 | `tb_uart` | PASS |
| 8N1 @ 921 600, FIFO depth 4 | `tb_uart` | PASS |
| 8E2 @ 2 000 000 | `tb_uart` | PASS |
| 8E2 @ 2 000 000, board example | `tb_uart_main` | PASS |

The testbenches are self-checking and need no external framework.
The full regression (12 configurations) runs in about a minute and performs
about 2.4 million checks.

**Bug found by the regression.** The first regression run failed at 2 Mbaud.
The baud counters counted `0 … freq/baud` *inclusive*, so every bit was one clock
too long. The start bit was one more clock longer, because the state machine spent
a cycle handing over from `START` to `DATA_OP`. At 50 MHz / 2 Mbaud that is a 4 %
rate error: back-to-back frames from a standard UART were lost.
I fixed both issues in the RTL. The worst measured TX rate error at 2 Mbaud went
from 4.00 % to 0.00 %.

## Project structure

```
uart_vhdl/
├── rtl/                     # synthesizable core
│   ├── fifo.vhd             #   circular buffer
│   ├── uart_transfer.vhd    #   TX shift register / bit timing
│   ├── uart_tx.vhd          #   transmitter: FIFO + parity generation
│   ├── uart_rx.vhd          #   receiver: synchronizer, FSM, FIFO
│   └── uart.vhd             #   IP top level
├── example/
│   └── uart_main.vhd        # board demo: replies "world" to "hello" and vice versa
├── quartus/                 # Quartus project (device, pins, settings)
├── sim/                     # verification (AI-written, see Authorship)
│   ├── tb/                  #   testbenches (tb_fifo, tb_uart, tb_uart_main), BFM, utilities
│   ├── rtl.f, tb.f          #   source lists in compile order
│   └── run_ghdl.sh          #   regression runner
└── README.md
```

## Interface (`uart`)

### Generics

| Generic             | Default    | Description |
|---------------------|------------|-------------|
| `freq`              | 50 000 000 | `clk` frequency, Hz |
| `baud`              | 115 200    | Baud rate |
| `amm_data_bits`     | 8          | Data bits per frame (1–16) |
| `amm_stop_bits`     | 1          | Stop bits (1–4) |
| `en_pairity`        | 0          | 1 = parity bit enabled |
| `pairity`           | `'0'`      | `'0'` = even, `'1'` = odd |
| `fifo_size`         | 16         | Depth of TX and RX FIFOs (1–16) |
| `rx_treshold_level` | 1          | `rx_water_level` is high when the RX FIFO holds more words than this |

### Ports

| Port             | Dir | Description |
|------------------|-----|-------------|
| `clk`, `rst`     | in  | Clock; synchronous active-high reset |
| `tx_enable`      | in  | Enables transmission |
| `place_for_tx`   | in  | Word to transmit |
| `send_byte`      | in  | One-cycle write strobe into the TX FIFO |
| `tx_fifo_full`   | out | TX FIFO is full |
| `tx_fifo_err`    | out | Write to a full FIFO; held until the next accepted write |
| `tx_busy`        | out | Transmission in progress |
| `tx_line`        | out | Serial output (idle high) |
| `rx_enable`      | in  | Enables reception |
| `rx_line`        | in  | Serial input (asynchronous) |
| `recieve_byte`   | in  | One-cycle read strobe from the RX FIFO |
| `place_for_rx`   | out | Read data, valid one cycle after the strobe |
| `rx_empty_fifo`  | out | RX FIFO is empty |
| `rx_fifo_err`    | out | Read from an empty FIFO |
| `rx_uart_err`    | out | Parity or framing error; cleared by the next valid frame |
| `rx_water_level` | out | RX FIFO fill level is above the threshold |

### Instantiation

```vhdl
uart_inst : entity work.uart
    generic map(freq => 50_000_000, baud => 115_200)
    port map(
        clk => clk, rst => rst,
        tx_enable => '1', tx_line => uart_tx, place_for_tx => tx_data,
        send_byte => tx_wr, tx_fifo_full => tx_full, tx_fifo_err => open, tx_busy => open,
        rx_enable => '1', rx_line => uart_rx, place_for_rx => rx_data,
        recieve_byte => rx_rd, rx_empty_fifo => rx_empty,
        rx_fifo_err => open, rx_uart_err => rx_err, rx_water_level => open);
```

## Simulation

Requires [GHDL](https://github.com/ghdl/ghdl) 3.0 or newer with VHDL-2008 support.

```bash
./sim/run_ghdl.sh                     # full regression
./sim/run_ghdl.sh 2M                  # only configurations whose name contains "2M"
WAVES=1 ./sim/run_ghdl.sh 8n1_115200  # also dump sim/build/<name>.ghw for GTKWave
TB_ARGS='-gg_tests=rx_overflow,rx_glitch' ./sim/run_ghdl.sh 8n1_115200   # selected tests
```

The script exits with code 0 only when every selected configuration passes, so it can run in CI.
Logs are written to `sim/build/<config>.log`.

### How the testbench works

- **Independent reference model.** `uart_bfm_pkg` implements the UART line from the
  protocol specification, not from the RTL. It drives frames, including baud offset and
  injected parity/stop errors. It decodes frames by sampling at ideal mid-bit points and
  measures every edge against the ideal bit grid.
- **Scoreboards.** Every word sent into the design is queued as expected data and
  compared with what comes out.
- **Self-checking.** Each run ends with `TEST PASSED` or `TEST FAILED` and a per-test summary.
- **Reproducible randomness.** Random data, gaps and clock phase come from a fixed
  seed (`-gg_seed=N`).
- **Functional coverage.** `tb_fifo` counts coverage bins (full, overflow, wrap,
  underflow, simultaneous push/pop on empty/partial/full, threshold rise/fall).
  A run fails if a reachable bin was never hit.
- **Mutation-checked.** Bugs were injected by hand into a copy of the RTL, and the
  regression caught all of them. UART (6): inverted TX parity, disabled RX parity
  check, disabled framing check, FIFO without wrap, stuck `push_err`, 5 % slow
  divider. FIFO (6): threshold `>=` instead of `>`, no bypass on empty, `full`
  off by one, wrap without moving the read pointer, `pop_err` never set, wrong
  size on simultaneous push/pop.

### Test list (`tb_fifo`)

A reference queue model runs in lock-step with the FIFO. Every cycle all six
outputs are compared with the model: `empty`, `full`, `threshold_act`, `push_err`,
`pop_err`, `byte_out_pl`.

| Phase                  | Checks |
|------------------------|--------|
| `reset`                | Output values after reset |
| `directed_corners`     | Pop on empty, push+pop on empty (bypass), fill, push on full, push+pop on full, drain |
| `random_fill_heavy`    | 80 % push / 20 % pop: mostly full, overflow and wrap |
| `random_drain_heavy`   | 20 % push / 80 % pop: mostly empty, underflow |
| `random_balanced`      | 50 % / 50 %: threshold crossings |
| `random_burst`         | 95 % / 95 %: simultaneous push and pop |
| `reset_during_traffic` | Reset with a partly filled FIFO, then recovery |

### Test list (`tb_uart`)

| Test             | Checks |
|------------------|--------|
| `reset`          | Output values after reset |
| `tx_directed`    | Corner patterns (0x00, 0xFF, 0x55, 0xAA, LSB, MSB): framing, parity, bit timing |
| `tx_random`      | Random stream with FIFO backpressure |
| `tx_overflow`    | `tx_fifo_full`, `tx_fifo_err`, rejected write |
| `tx_disable`     | No output while `tx_enable = 0`; resumes on enable |
| `rx_directed`    | Reception of corner patterns |
| `rx_random`      | Random stream with random gaps and clock phase |
| `rx_baud_tol`    | Back-to-back frames with the sender at ±2 % baud offset |
| `rx_parity_err`  | Parity error: flag set, word dropped, flag cleared |
| `rx_framing_err` | Broken stop bit |
| `rx_glitch`      | A short low pulse is not taken as a start bit |
| `rx_disable`     | No reception while `rx_enable = 0` |
| `rx_overflow`    | Oldest data overwritten; `rx_water_level` |
| `rx_pop_empty`   | `rx_fifo_err` on a read from an empty FIFO |
| `full_duplex`    | Simultaneous TX and RX |
| `reset_traffic`  | Reset in the middle of a frame, then recovery |

`tb_uart_main` is a system test of the board example: "hello" → "world",
"world" → "hello", "xyhello" → "world", other text → no reply.

## Building in Quartus

Open `quartus/uart.qpf` in Quartus Prime Lite 25.1 and run *Compile Design*.
The top level is `uart_main`. Device and pins are set in `quartus/uart.qsf`:
5CSEBA6U23I7; `clk` on V11, `rx_line` on Y15, `tx_line` on AA15; 3.3-V LVTTL.

## Limitations

- The bit rate is quantized to whole clock cycles. At 50 MHz, 921 600 baud has a
  0.47 % error (54 clocks per bit instead of 54.25).
- The receiver samples about 3 clocks after the mid-bit point: 2 synchronizer stages
  plus edge detection. At high baud rates this reduces timing margin on one side.

## Roadmap

- [ ] Add `quartus/uart.sdc`
- [x] Standalone FIFO testbench
- [x] Validate on hardware at 2 Mbaud with continuous back-to-back traffic
