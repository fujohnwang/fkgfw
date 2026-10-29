# One shared provider avoids duplicate issuance when both protocols use a domain.
def owned: .tag == "vless-tls-in" or .tag == "anytls-in";
if any(.inbounds[]; (owned | not) and .tls.certificate_provider == "fkgfw-acme") then
  error("A custom inbound references fkgfw-acme; use a separate certificate provider")
else . end
| ([.inbounds[] | select(owned) | .tls.server_name] | unique) as $domains
| ([.certificate_providers[]? | select(.tag == "fkgfw-acme")][0] // null) as $provider
| if $provider != null and ($provider.type != "acme" or $provider.data_directory != "/etc/sing-box/acme") then
    error("The certificate provider tag fkgfw-acme is already in use") else . end
| if ($domains | length) > 0 then
    .certificate_providers = ([.certificate_providers[]? | select(.tag != "fkgfw-acme")]
      + [($provider // {type: "acme", tag: "fkgfw-acme", provider: "letsencrypt", key_type: "p256",
          data_directory: "/etc/sing-box/acme", disable_tls_alpn_challenge: true}) | .domain = $domains])
  elif $provider != null then
    .certificate_providers |= map(select(.tag != "fkgfw-acme"))
    | if .certificate_providers == [] then del(.certificate_providers) else . end
  else . end
