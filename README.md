# DDR1 SDRAM Functional Model (SystemVerilog)

This project implements a functional RTL model of a DDR1 SDRAM controller based on the JEDEC JESD79F specification.

## ✨ Features

- JEDEC-compliant command decode: ACT, READ, WRITE, PRECHARGE, REFRESH, MRS
- Support for key timing constraints:  
  `tRCD`, `tRP`, `tRAS`, `tRFC`, `tWR`, `tMRD`, `tRRD`, `tXSR`
- Per-bank row activation, precharge, and state tracking
- Self-refresh and power-down support via CKE control
- Mode Register decode (burst length, CAS latency, burst type)
- Modular FSM-based control path
- Modular support to be driven by DDR Controller
- Forward-compatible design for datapath integration (burst handling)

## 📂 File Structure

| File/Folder | Description |
|-------------|-------------|
| `rtl/control_logic.sv` | Command FSM, bank tracking, and timing enforcement |
| `rtl/memory_array.sv` | Memory model and burst address generation |
| `DDR1-SDRAM-Controller-Functional-Design/tb/` | Top-level testbench combined with DDR controller (repository) testbench |

## ✅ Status

- Control logic: ✔️ Complete  
- Address decode: ✔️ Complete  
- Datapath (burst/data handling): ✔️ Complete  
- Memory array abstraction: ✔️ Complete  

## 🚀 Author

Ali Yusuf Askari Husain  
M.Tech Microelectronics | Intel Intern | RTL/Verification Enthusiast  
📧 ali.yusuf.ay.110@gmail.com  
🔗 [LinkedIn](https://www.linkedin.com/in/ali-yusuf-73746a13a/)
