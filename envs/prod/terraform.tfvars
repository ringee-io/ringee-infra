# Production has run on AWS since the cutover of 7 November 2026 (README,
# "Corte"). running = false would stop every service. In git so CI plans
# against the same state.
running = true

# Tier B runs 2 API tasks. Keep 1 until AWS-06 (dialer SSE over Redis) has run
# stable in production for a few days (AWS-25).
api_min_tasks = 1

# The alarms and their SNS topic are created with running = true; the address
# has to confirm the subscription email AWS sends then.
alarm_emails = ["edison@getringee.com"]

# External check of https://api.ringee.io/api/health, on since the DNS cutover.
health_check_fqdn = "api.ringee.io"
