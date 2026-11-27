# Staging is up (README, "Levantar staging", step 9): services run on weekdays
# 08:00-22:00 Santo Domingo, and module.stack.module.schedule stops them outside
# those hours. In git so CI plans against the same state.
running = true

# Shared Telnyx account coordination; accepts only this production peer.
provider_dispatch_peering_id = "pcx-0814da0bc46d70420"
