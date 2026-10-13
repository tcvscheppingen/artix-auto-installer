# Artix Auto Installer
Personal script for installing Artix Linux with Dinit

After having installed Aritx/Arch manually multiple times, I wanted to automate the installation, so I created this script
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

### Disclaimer
I wrote this script with assistance from a Large Language Model.   
I have reviewed the script in its entirety and validated it by running it in a VM.
