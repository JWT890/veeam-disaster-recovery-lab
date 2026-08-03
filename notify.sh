#!/bin/bash
#
# Veeam Agent for Linux - post-job email notification
# Triggered via: --postjob "/opt/veeam/notify.sh"
#
# Fill in the CONFIG section below, then copy this file to /opt/veeam/notify.sh
# on the Veeam VM and chmod +x it.

### ---------- CONFIG ---------- ###
JOB_NAME="TestVM-Backup"

SMTP_HOST="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="your.email@gmail.com"        # <-- your Gmail address
SMTP_PASS="xxxxxxxxxxxxxxxx"            # <-- 16-char app password, no spaces
MAIL_FROM="your.email@gmail.com"        # <-- usually same as SMTP_USER
MAIL_TO="your.email@gmail.com"          # <-- where you want alerts sent
### ----------------------------- ###

# Grab the most recent session line for this job
LATEST_SESSION=$(veeamconfig session list | grep "^${JOB_NAME}" | tail -1)

if [ -z "$LATEST_SESSION" ]; then
    STATUS="UNKNOWN"
else
    # State is one column in the space-padded output - pull it out
    STATUS=$(echo "$LATEST_SESSION" | awk '{for(i=1;i<=NF;i++){if($i=="Success"||$i=="Failed"||$i=="Running"||$i=="Warning"){print $i; exit}}}')
fi

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S %Z")
HOSTNAME=$(hostname)

if [ "$STATUS" == "Success" ]; then
    SUBJECT="[Veeam] Backup SUCCESS - ${JOB_NAME} on ${HOSTNAME}"
elif [ "$STATUS" == "Failed" ]; then
    SUBJECT="[Veeam] Backup FAILED - ${JOB_NAME} on ${HOSTNAME}"
else
    SUBJECT="[Veeam] Backup job finished with status: ${STATUS} - ${JOB_NAME} on ${HOSTNAME}"
fi

BODY="Job: ${JOB_NAME}
Host: ${HOSTNAME}
Status: ${STATUS}
Time: ${TIMESTAMP}

Latest session line:
${LATEST_SESSION}
"

# Build the raw email and send via curl SMTP
curl --ssl-reqd \
  --url "smtp://${SMTP_HOST}:${SMTP_PORT}" \
  --user "${SMTP_USER}:${SMTP_PASS}" \
  --mail-from "${MAIL_FROM}" \
  --mail-rcpt "${MAIL_TO}" \
  --upload-file - <<EOF
From: Veeam Lab <${MAIL_FROM}>
To: ${MAIL_TO}
Subject: ${SUBJECT}

${BODY}
EOF

exit 0
