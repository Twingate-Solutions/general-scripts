# Twingate Bash Scripts

The scripts in this folder are meant to be used as the basis of scripts that can be used to automate various administrative tasks.

## Scripts

- **`user_not_logged_in_notification.sh`**: Bash script to automate sending a notification to a user when they are not logged in to the Twingate Client application. This script can be used to remind users to log in to the Twingate Client application, and to provide them with instructions on how to do so. Requires **`template_com.twingate.logincheck.plist`** if automating via launchd is needed.
- **`client_linux_firewall_check.sh`**: Bash script to check the state of the firewall and report it back to the user.
- **`client_macos_sys-info.sh`**: Bash script to be run on a MacOS system, to gather various system information and put into a file for sending to Twingate support for troubleshooting.
- **`ubuntu-client-installer.sh`**: Bash script to install the Twingate client on an Ubuntu system, and also to configure special DNS settings.
