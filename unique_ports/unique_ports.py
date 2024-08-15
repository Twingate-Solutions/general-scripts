# -*- coding: utf-8 -*-
"""This Script will ingest a Twingate Network Events report and output a list of unique hosts and ports that are found."""

import json,requests,re
import pandas as pd
from types import SimpleNamespace
import datetime, time, logging, sys, base64, math
from zoneinfo import ZoneInfo
from urllib.request import urlopen
from json import load


if len(sys.argv) != 3:
    print('usage: python unique_ports.csv [input filename] [output filename]')
    sys.exit() 
inputfile = sys.argv[1]
outputfile = sys.argv[2]
################################################################

# Use the following functions to extract what you need

################################################################

## every function below should take a DF (and other parameters if needed) as input ##
## and return a DF as output to allow chaining functions ##

# converts an admin console connector reports to a flattened normalized DF
def convert_admin_console_report_to_df(conn_output,tz=None):
    df = pd.read_csv(conn_output)
    df = df.rename(columns={"device_id":"device.id","start_time" : "timestamp.readable","status" : "connection.error_message","resource_domain" : "resource.address","applied_rule" : "resource.applied_rule","bytes_received" : "connection.rx","bytes_transferred" : "connection.tx","resource_id" : "resource.id","remote_network" : "remote_network.name","remote_network_id" : "remote_network.id","protocol" : "connection.protocol","resource_port" : "connection.resource_port","resource_ip" : "connection.resource_ip","connector_id" : "connector.id","user": "user.email", "user_id": "user.id", "client_ip" : "connection.client_ip","connector" : "connector.name"})
    df = df.drop(columns=['relays', 'relay_ips','relay_ports','end_time'])
    df['timestamp.readable'] = df['timestamp.readable'].str.replace(' UTC', '')
    df['timestamp'] = df['timestamp.readable'].apply(date_to_epoch)
    df['timestamp.readable'] = df['timestamp'].apply(epoch_to_date,args=(tz,))
    df['connector.id'] = df['connector.id'].apply(convert_id_to_api_id,args=("connector",))
    df['remote_network.id'] = df['remote_network.id'].apply(convert_id_to_api_id,args=("remotenetwork",))
    df['resource.id'] = df['resource.id'].apply(convert_id_to_api_id,args=("resource",))
    df['user.id'] = df['user.id'].apply(convert_id_to_api_id,args=("user",))
    df['device.id'] = df['device.id'].apply(convert_id_to_api_id,args=("device",))
    return df

# converts ANALYTICS output into a flattened normalized DF (except for Relay info)
# it is obtained by running the following command:
# journalctl -u twingate-connector --since "X min ago" | grep "ANALYTICS" | sed 's/.* ANALYTICS//' | sed 'r/ /\ /g' > somefile
def convert_connector_output_to_df(conn_output,tz=None):
    df = pd.DataFrame()
    f = open(connector_log, "r")
    for line in f.readlines():
        data = json.loads(line)
        df1 = pd.json_normalize(data)
        df = pd.concat([df, df1])

    # adding a human readable timestamp to each line
    df['timestamp.readable'] = df['timestamp'].apply(epoch_to_date,args=(tz,))

    # object ids in Connector logs are the internal DB ids which are base64 decoded versions of API Ids.
    # converting internal Ids to API Ids in DF
    df['connector.id'] = df['connector.id'].apply(convert_id_to_api_id,args=("connector",))
    df['remote_network.id'] = df['remote_network.id'].apply(convert_id_to_api_id,args=("remotenetwork",))
    df['resource.id'] = df['resource.id'].apply(convert_id_to_api_id,args=("resource",))
    df['user.id'] = df['user.id'].apply(convert_id_to_api_id,args=("user",))
    df['device.id'] = df['device.id'].apply(convert_id_to_api_id,args=("device",))
    df[['connection.error_message']] = df[['connection.error_message']].fillna('NORMAL')
    # dropping relay info
    df = df.drop(columns=['relays','connection.cbct_freshness'])

    return df

def get_all_timezones():
    zoneinfo.available_timezones()

# returns the unique list of addresses connected to by users.
def get_address_activity(df,addr):
    logging.debug("getting list of activities for a given address.")
    return df.loc[df["resource.address"] == addr]

def get_resource_activity(df,resource):
    logging.debug("getting list of activities for a given resource.")
    return df.loc[df["resource.applied_rule"] == resource]

def get_endpoints_from_resource_activity(df,resource):
    logging.debug("getting list of activities for a given resource.")
    adf = df.loc[df["resource.applied_rule"] == resource]
    return adf["resource.address"].unique()

def get_unique_addresses(df):
    logging.debug("getting unique list of endpoints hit by clients.")
    return df["resource.address"].unique()

def get_unique_resources(df):
    logging.debug("getting unique list of resources hit by clients.")
    return df["resource.applied_rule"].unique()

def get_user_activity(df,user):
    logging.debug("getting all records for a given user.")
    return df.loc[df["user.email"] == user]

def get_user_client_ips(df,user):
    logging.debug("getting all records for a given user.")
    df1 = df.loc[df["user.email"] == user]
    return df1["connection.client_ip"].unique()

def get_connector_ids(df):
    return df["connector.id"].unique()

def get_connector_names(df):
    return df["connector.name"].unique()

def get_rn_ids(df):
    return df["remote_network.id"].unique()

def get_rn_names(df):
    return df["remote_network.name"].unique()

def get_activities_for_remote_network(df,rnid):
    #s,dbid = convert_api_id_to_id(rnid)
    return df.loc[df["remote_network.id"] == rnid]

def get_activities_for_connector(df,connid):
    #s,dbid = convert_api_id_to_id(connid)
    return df.loc[df["connector.id"] == connid]

def get_activity_between_dates(df,before,after,localtz):
    # assuming before and after dates are in localtz, they need to be adjusted to UTC before comparison
    logging.debug("converting before date from string to datetime.")
    dt_before = datetime.datetime.strptime(before, "%Y-%m-%d %H:%M:%S.%f")

    logging.debug("converting after date from string to datetime.")
    dt_after = datetime.datetime.strptime(after, "%Y-%m-%d %H:%M:%S.%f")

    logging.debug("converting before date to UTC.")
    dt_before_utc = tz_to_utc(dt_before,localtz)

    logging.debug("converting after date to UTC.")
    dt_after_utc = tz_to_utc(dt_after,localtz)

    logging.debug("before date in UTC: "+str(dt_before_utc))
    logging.debug("after date in UTC: "+str(dt_after_utc))

    logging.debug("converting UTC dates to epoch.")
    before_epoch = date_to_epoch(str(dt_before_utc).replace("+00:00",""))
    logging.debug("before date in UTC to epoch: "+str(before_epoch))

    after_epoch = date_to_epoch(str(dt_after_utc).replace("+00:00",""))
    logging.debug("after date in UTC to epoch: "+str(after_epoch))

    #print("before:"+str(before_epoch)+" and after: "+str(after_epoch))
    return df[df['timestamp'].between(after_epoch, before_epoch)]

# return rows that have an actual error message
def get_errors(df):
    #return df[~df['connection.error_message'].isna()]
    return df[~df['connection.error_message'].str.startswith('NORMAL')]

def get_failures(df):
    if "event_type" in df:
        return df.loc[df["event_type"] == "failed_to_connect"]


################################################################

# Ignore the following functions, they provide tooling for other useful functions

################################################################


# alternate method to extract IP Geo location info
def get_ip_info(addr=''):
    str_addr = str(addr)
    if str_addr == 'nan':
        return {}
    else:
        url = 'https://ipinfo.io/' + str_addr + '/json'
    res = urlopen(url)
    #response from url(if res==None then check connection)
    data = load(res)
    #will load the json response into data
    return data

# Events in the log show internal DB IDs as opposed to API IDs (visible in the Admin Console)
# the following function converts the DB ID to API ID
def convert_id_to_api_id(id,objecttype):
    if objecttype:
        encoded = base64.b64encode((objecttype.capitalize()+":"+str(id)).encode('ascii'))
        return encoded.decode("utf-8")
    else:
        return None

# Opposite of previous function, converts an API ID to DB ID
def convert_api_id_to_id(id):
    decoded = base64.b64decode(id)
    objname,dbid = decoded.decode("utf-8").split(":")
    return objname.lower(),dbid

# converts an epoch time to a human readable date
def epoch_to_date(timestamp,tz):
    s, ms = divmod(timestamp, 1000)  # (1236472051, 807)
    mydate = '%s.%03d' % (time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(s)), ms)
    utc_time = datetime.datetime.strptime(mydate, "%Y-%m-%d %H:%M:%S.%f")
    if tz != None:
        #logging.debug("tz passed as a parameter: "+tz)
        return str(utc_to_tz(utc_time,tz))
    else:
        #logging.debug("tz not passed as a parameter")
        return str(utc_time)

def utc_to_tz(utc_time,tz):
    utc = ZoneInfo('UTC')
    localtz = ZoneInfo(tz)
    utctime = utc_time.replace(tzinfo=utc)
    localtime = utctime.astimezone(localtz)
    return localtime

def tz_to_utc(a_time,tz):
    utc = ZoneInfo('UTC')
    localtz = ZoneInfo(tz)
    atime = a_time.replace(tzinfo=localtz)
    utc_time = atime.astimezone(utc)
    return utc_time

# converts a human readable date to epoch time
def date_to_epoch(adate):
    utc_time = datetime.datetime.strptime(adate, "%Y-%m-%d %H:%M:%S.%f")
    epoch_time = (utc_time - datetime.datetime(1970, 1, 1)).total_seconds()
    return epoch_time*1000

# returns a DF as CSV
def get_df_as_csv(df):
    return df.to_csv(index=True)

"""## Configuring your environment

1. Specify the Timezone you are in (all timestamps will be converted to your timezone
2. Specify the file you want to load (the export file from the Admin Console)
3. Run the cell (to produce the DF with all events)
"""

# specify the timezone you are in, it will become visible in the dataframe and can be used to filter activities based on localtime
local_tz = 'America/Los_Angeles'
#local_tz=None

full_console_report = inputfile

# For a report extracted from the Admin Console
# NOTE: depending on the size of the report, this cell may take several minutes to run
# for example, a 5M entry file (1.1Gb) takes about 2-3 minutes to load into a DF
df = convert_admin_console_report_to_df(full_console_report,local_tz)

# we only need user email, port, address, protocol
df_redux = df.drop(columns=['timestamp.readable','connection.client_ip','connector.name','device.id','connector.id','resource.id','connection.error_message','connection.tx','connection.rx','remote_network.name','remote_network.id','service_account','service_account_id','service_account_key','service_account_key_id','timestamp'])
df_redux2 = df_redux.drop_duplicates()
df_redux2.to_csv(outputfile, index=False, header=True)
print("Results output to " + outputfile)