# Merge protocol selections into the existing server. Other inbounds and
# unrelated settings survive; retained managed inbounds are copied verbatim.
def managed: ["vless-in", "hy2-in", "vmess-in", "vless-ws-in", "vless-tls-in", "anytls-in"];
def list: if type == "array" then . else [.] end;
def prune($removed):
  map(if .type == "logical" then
        if any(.. | objects | .inbound? // empty | list | .[]; . as $tag | $removed | index($tag)) then
          error("A custom logical rule references a removed inbound; update that rule first")
        else . end
      elif .inbound then
        .inbound = ((.inbound | list) - $removed) | select(.inbound | length > 0)
      else . end);
if ($selected | length) == 0 or ($selected - managed | length) > 0
   or ($selected | unique | length) != ($selected | length) then
  error("Invalid protocol selection") else . end
| . as $old
| (managed - $selected) as $removed
| .inbounds = ([.inbounds[]? | select(.tag as $tag | $removed | index($tag) | not)]
  + [$selected[] as $tag | select(any($old.inbounds[]?; .tag == $tag) | not)
      | ([$additions[] | select(.tag == $tag)][0] // error("Missing parameters for " + $tag))])
| if ([.inbounds[].tag] | length) != ([.inbounds[].tag] | unique | length) then
    error("Duplicate inbound tags") else . end
| if .route.rules then .route.rules |= prune($removed) else . end
| if .dns.rules then .dns.rules |= prune($removed) else . end
