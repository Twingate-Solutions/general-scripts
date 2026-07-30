# Twingate Bash Scripts

The scripts in this folder are meant to be used as the basis of scripts that can be used to automate various administrative tasks. They're templates/starting points — read each script's header comments for its expected arguments before running it. Most assume Bash and standard system tools.

## Scripts

- **`user_not_logged_in_notification.sh`** (macOS): Bash script to automate sending a notification to a user when they are not logged in to the Twingate Client application. This script can be used to remind users to log in to the Twingate Client application, and to provide them with instructions on how to do so. Requires **`template_com.twingate.logincheck.plist`** if automating via launchd is needed.
- **`client_linux_firewall_check.sh`** (Linux/Ubuntu): Bash script to check the state of the firewall and report it back to the user.
- **`client_macos_sys-info.sh`** (macOS): Bash script to be run on a MacOS system, to gather various system information and put into a file for sending to Twingate support for troubleshooting.
- **`ubuntu-client-installer.sh`** (Linux/Ubuntu): Bash script to install the Twingate client on an Ubuntu system, and also to configure special DNS settings.
- **`keep-one-behind.sh`** (Linux/Ubuntu, Debian-based): Bash script that allows you to update a package on Ubuntu/Debian systems but keeping one version back from latest.  This would be useful in a situation (such as updating the Twingate Connector) where you want to stay on a more stable/older version rather than the bleeding edge.
