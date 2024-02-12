# Twingate Exclude Group Setup

This Bash script automates the process of adding users to an exclude group in Twingate based on their membership in an include group. The script utilizes the Twingate Python CLI (`tgcli.py`) to interact with the Twingate API and perform the necessary operations.

This script would be used in a situation where you have a large number of users, but only want a few of them to be set up to use Internet Security.

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
./setup_exclude_group.sh <include_group_id> <exclude_group_id> <twingate_network_name> <api_token>
```

- `<include_group_id>`: The ID of the include group.
- `<exclude_group_id>`: The ID of the exclude group to be updated.
- `<twingate_network_name>`: The name of your Twingate network.
- `<api_token>`: Your Twingate API token.

### Example

```bash
./setup_exclude_group.sh 123456789 987654321 mynetworkname tgapitoken
```

Group IDs can be obtained from the URL in the Twingate Admin Console, for example: `https://networkname.twingate.com/groups/123456789`

## Script Explanation

The script performs the following steps:

1. **Authenticate with Twingate API:** Logs in using the Twingate Python CLI to obtain a session ID.
2. **Get Users from Include Group:** Retrieves the list of user IDs from the specified include group.
3. **Get All Users:** Retrieves the list of all user IDs in the Twingate network.
4. **Identify Users to Exclude:** Compares the user IDs from the include group with all user IDs to identify users not in the include group.
5. **Update Exclude Group:** Adds the identified users to the specified exclude group.
