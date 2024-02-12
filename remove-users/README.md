# Twingate Remove Users from Group

This Bash script facilitates the removal of all users from a specified group in Twingate. The script must be executed within the same folder as `tgcli.py` and requires the group ID as a parameter.

## Prerequisites

Before running the script, ensure the following prerequisites are met:

1. Install `jq`:
    ```bash
    sudo apt install jq
    ```

2. Install the [Twingate Python CLI](https://github.com/Twingate-Labs/Twingate-CLI) and its dependencies (`requests` and `pandas`):
    ```bash
    # Install Twingate Python CLI
    pip install tgcli

    # Install required dependencies
    pip install requests pandas
    ```

## Usage

Run the script using the following command:

```bash
./remove_users.sh <group_id> <network_name> <api_token>
```

- `<group_id>`: The ID of the group from which users will be removed.
- `<network_name>`: This is your Twingate network name, ie networkname.twingate.com.
- `<api_token>`: This is a Twingate API token, with read/write permissions.

### Example

```bash
./remove_users.sh 123456789
```

## Script Explanation

The script performs the following steps:

1. **Authenticate with Twingate API:** Logs in using the Twingate Python CLI to obtain a session ID.
2. **Get Users from Group:** Retrieves the list of user IDs from the specified group.
3. **Remove Users from Group:** Iterates through the user IDs and removes each user from the specified group.