This script will ingest a Twingate Network Events report (Admin > Reports > Network Events) and output all unique host and port combinations that were actually accessed over Twingate to a CSV file.

If you currently have resources defined with wide or universal port allowances, this may help determine what ports are actually being accessed by your users, and make it easier to tighten things up.

Usage:

`python unique_ports.py [input CSV filename] [output CSV filename]`

For example, `python unique_ports.py network_events.csv unique_ports.csv` would ingest the network_events.csv file and output the unique_ports.csv. The output file will be created if it doesn't exist, and overwritten if it does.