# Artix Auto Installer
Personal script for installing Artix Linux with Dinit

After having installed Aritx/Arch manually multiple times, I wanted to automate the installation, so I created this script.  
The default locale and keymap are my own preferences, but can be changed during the installation.

The installation script is designed to work on a UEFI Lenovo ThinkPad, but will likely work on other systems as well.

The script will do the following:
- Install Artix Linux with Dinit as the init system and with an encrypted root partition.
- Optionally:
  - Enable TimeShift for rollbacks in case the system breaks.
  - Install the LTS Linux kernel as fallback
  - Enable a firewall (UFW) to improve security.
  - Enable the Arch User Repository (AUR) and install `yay` as AUR helper.
 
The script will **not** do the following:
- Install a desktop environment or window manager.  
  You can use my other [installation script](https://github.com/tcvscheppingen/DARBS) to install my config of DWM and some other tools.

## Usage

Boot the Artix **base dinit** ISO in UEFI mode with Secure Boot off, log in as `root` (password `artix`), connect to the internet, then:

```bash
pacman -Sy git
git clone https://github.com/tcvscheppingen/artix-auto-installer.git
cd artix-auto-installer
./artix-install.sh
```
To preset some or all answers, copy `install.conf.example`, fill it in and run `./artix-install.sh --config install.conf`. Anything you leave empty is asked for.

If you want to test the installation script you can do so by running `test/run-container-test.sh`
