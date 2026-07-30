# Filter Network Events Report by User

Filters a Twingate Network Events report CSV (from Admin Console → Settings →
Reports) down to a single user's events.

## Prerequisites

Python 3 only — the script uses the standard library (`sys`, `csv`) with no
external dependencies.

## Usage

```bash
python3 filter-by-user.py <input-file> <user@domain.com> <output-file>
```

### Example

A sample input file, `testfile.csv`, is included in this folder:

```bash
python3 filter-by-user.py testfile.csv testuser@domain.com testfileoutput.csv
```
