# Migrate only settings used by the old server templates; leave other custom
# settings intact so the new binary can reject unsupported configurations.
. as $old
| [.outbounds[]? | select(.type == "block") | .tag] as $blocked
| [.outbounds[]? | select(.type == "dns") | .tag] as $dns
| if (($blocked + $dns) | index($old.route.final)) != null then
    error("Cannot automatically migrate a legacy special outbound used as route.final")
  else . end
| .outbounds |= map(select(.type != "block" and .type != "dns"))
| if .route.rules then
    .route.rules |= walk(if type == "object" and .outbound then
      .outbound as $target
      | if ($blocked | index($target)) != null then del(.outbound) | .action = "reject"
        elif ($dns | index($target)) != null then del(.outbound) | .action = "hijack-dns"
        else . end
      else . end)
  else . end
| [.inbounds[] | select(.sniff == true) | .tag] as $sniff
| [.inbounds[] | select(.domain_strategy != null and .domain_strategy != "")
    | {inbound: [.tag], action: "resolve", strategy: .domain_strategy}] as $resolve
| if ($sniff | length) > 0 or ($resolve | length) > 0 then
    if any(.inbounds[]; (.sniff == true or .domain_strategy != null) and (.tag == null or .tag == "")) then
      error("Legacy inbound options require an inbound tag for migration")
    else . end
    | .route.rules = ((if ($sniff | length) > 0 then [{inbound: $sniff, action: "sniff"}] else [] end)
        + $resolve + (.route.rules // []))
  else . end
| .inbounds |= map(del(.sniff, .sniff_override_destination, .domain_strategy))
