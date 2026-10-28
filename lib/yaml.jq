# JSON scalar quoting preserves strings such as "0123", "false" and IPv6.
# Escape characters YAML forbids or treats as line breaks inside quoted text.
def yaml_scalar:
  tojson
  | gsub("(?<c>[\u007f-\u009f\u2028\u2029])";
      (.c | explode[0]) as $n
      | "\\u" + ([4096, 256, 16, 1]
          | map((($n / . | floor) % 16) as $d | "0123456789abcdef"[$d:$d+1])
          | join("")));

def block: (type == "object" or type == "array") and length > 0;
def yaml($indent):
  if type == "object" and length > 0 then
    to_entries[]
    | ($indent + (.key | yaml_scalar) + ":") as $key
    | .value
    | if block then $key, yaml($indent + "  ")
      else $key + " " + yaml_scalar end
  elif type == "array" and length > 0 then
    .[]
    | if block then ($indent + "-"), yaml($indent + "  ")
      else $indent + "- " + yaml_scalar end
  else $indent + yaml_scalar end;

yaml("")
