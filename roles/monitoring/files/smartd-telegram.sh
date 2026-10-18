#!/bin/bash
# Managed by Ansible (monitoring role).
# Called by smartd-runner with the SMARTD_* variables set by smartd.
/usr/local/sbin/notify-telegram "💽 SMART WARNING

🖥️ Server: $(hostname)
Device: ${SMARTD_DEVICESTRING:-${SMARTD_DEVICE:-unknown}}
Type: ${SMARTD_FAILTYPE:-unknown}

${SMARTD_MESSAGE:-no details}"
