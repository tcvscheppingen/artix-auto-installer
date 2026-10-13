# Artix Auto Installer
Personal script for installing Artix Linux with Dinit

After having installed Aritx/Arch manually multiple times, I wanted to automate the installation, so I created this script.  
The default locale and keymap are my own preferences, but can be changed during the installation.

The installation script is designed for UEFI PCs and laptops with an Intel or AMD CPU.

The script will do the following:
- Install Artix Linux with Dinit as the init system and with an encrypted root partition.
- Rank the package mirrors by speed (`rankmirrors`), for the installation and the installed system.
- Enable a firewall (UFW) that blocks all incoming connections and allows outgoing ones.
- Show a summary of the installation at the end, with what to do next. You can save it as `~/artix-install-summary.md` in the new system.
- Optionally:
  - Install the LTS Linux kernel as fallback
  - Install NVIDIA's proprietary driver, when an NVIDIA GPU is found. The right driver for the card's generation is picked automatically.
  - Use the older HDA sound driver instead of SOF, when the Intel sound chip has a DSP. Use this when SOF only gives a "Dummy Output"; the built-in digital microphones don't work with the HDA driver.
  - Enable the Arch User Repository (AUR) and install `yay` as AUR helper.
 
The script will **not** do the following:
- Install a desktop environment or window manager, or the Intel/AMD graphics drivers (mesa, Vulkan, VA-API).  
  You can use my other [installation script](https://github.com/tcvscheppingen/DARBS) to install my config of DWM, the graphics drivers and some other tools.

## Usage

Boot the Artix **base dinit** ISO in UEFI mode with Secure Boot off, log in as `root` (password `artix`), connect to the internet, then:

```bash
pacman -Sy git
git clone https://github.com/tcvscheppingen/artix-auto-installer.git
cd artix-auto-installer
chmod +x artix-install.sh
./artix-install.sh
```
To preset some or all answers, copy `install.conf.example`, fill it in and run `./artix-install.sh --config install.conf`. Anything you leave empty is asked for.

## Testing

`test/run-container-test.sh` tests the installer with Docker: it runs the installer in an Artix container against a disk image, checks the installed system, and boots it in QEMU (UEFI, NVMe) to check it from the inside.

```bash
test/run-container-test.sh                    # shellcheck, install, verify, boot
test/run-container-test.sh all --darbs        # also install DARBS, check it and boot again
DARBS_DIR=~/src/DARBS test/run-container-test.sh all --darbs   # a local DARBS checkout
```

It works on macOS (Docker Desktop) and Linux (Docker Engine). The install and check stages need privileged containers, which on Linux share the host's kernel; the test only uses its own loop devices and device-mapper names, and doesn't change the host's EFI boot entries, clock, swap or console keymap.

The results end up in `test/out/test-report.pdf` when pandoc and a TeX engine (xelatex, lualatex, pdflatex or tectonic) are installed, otherwise in `test/out/test-report.md`.

## Disclaimer
I wrote this script with assistance from a Large Language Model.   
I have reviewed the script in its entirety and validated it by running it in a VM.

