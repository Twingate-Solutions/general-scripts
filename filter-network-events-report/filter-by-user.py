# Python script that will take the incoming Twingate network events file
# and filter the events by user and write the filtered events to a new file

# The script will be executed as follows:
# python3 filter-by-user.py <input-file> <user> <output-file>

# For testing you can run the following command with the provided sample file:
# python3 filter-by-user.py testfile.csv testuser@domain.com testfileoutput.csv

# This will provide a filtered list of events for just testuser@domain.com.

import sys
import csv

# Validate the arguments
if len(sys.argv) != 4:
    print("Usage: python filter-by-user.py <input-file> <user@domain.com> <output-file>")
    sys.exit(1)

# Assign the arguments to variables
input_file = sys.argv[1]
user = sys.argv[2]
output_file = sys.argv[3]

# Open the input file
with open(input_file, 'r', encoding='utf-8') as f:
    reader = csv.reader(f)
    header = next(reader)
    events = [row for row in reader if row[2] == user]

# Write the filtered events to the output file
with open(output_file, 'w', encoding='utf-8', newline='') as fo:
    writer = csv.writer(fo)
    writer.writerow(header)
    writer.writerows(events)