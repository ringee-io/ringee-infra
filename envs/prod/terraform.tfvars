# Production is built ahead of the cutover (README, "Orden de arranque"): the
# whole stack exists with every service at 0 tasks until cutover night (plan
# §10, step 10). In git so CI plans against the same state.
running = false

# Tier B runs 2 API tasks. Keep 1 until AWS-06 (dialer SSE over Redis) has run
# stable on Railway for a few days.
api_min_tasks = 1

# The alarms and their SNS topic are created with running = true; the address
# has to confirm the subscription email AWS sends then.
alarm_emails = ["edison@getringee.com"]
