# hwsynlab_2024_project

Final project for **Hardware Synthetic Laboratory Class 2024**

## 📌 Project Overview

This project implements a **digital image viewer system** on FPGA that:

- Reads image data from a microSD card using the **SPI protocol**
- Buffers the image into internal registers (LUTRAM)
- Displays the image on a **640×480 VGA monitor**
- Supports **grayscale display toggle**
- Calculates and displays **checksum** after reading

## ⚙️ Key Design Decisions

### ✅ SD Card Interface via SPI Mode

- **Implementation**
  - Custom `sd_controller` handles SPI initialization and block reads (CMD0, CMD8, CMD55, CMD41 loop)
  - Reads 72 sectors (512 bytes each) and stores image data in `reg [15:0] buffer [0:3071]`

---

### 🖥️ VGA Display (640×480 @ 60Hz)

- Pixel resolution downscaled to **64×48** for buffer size efficiency
- Displayed using **`vga_sync`** module generating sync signals and pixel positions
- Scaled by dividing `x` and `y` by 10 to map VGA coordinates to buffer index
- Toggle between **color and grayscale mode** via button input

---

### 📊 Memory & Image Buffer

- Used **register array** instead of BRAM for small memory footprint (6 KB)
- Each pixel = 16 bits (RGB 4:4:4 equivalent)
- Buffered image fits perfectly in `3072` entries

---

### ✔️ Checksum Calculation

- Performed **after all image sectors are read**
- Prevents interference with display/read logic
- Uses **modulo 65521** (largest 16-bit prime) to compute checksum
- Displayed via LEDs

---
