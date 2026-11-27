# The one loader of the harness registry. Every *.json of one directory is passed
# as its own --rawfile, named by its file name, so each parses alone (read as one
# stream, a truncated file can swallow the next one):
#   for f in <dir>/*.json; do a+=(--rawfile "${f##*/}" "$f"); done
#   jq -nc "${a[@]}" --arg out registry -f registry.jq   (the descriptors)
#   jq -nr "${a[@]}" --arg out tokens -f registry.jq     (token path globs)
# It errors on a malformed descriptor or a missing listed one, so a caller that
# gets a non-zero status refuses. A parseable descriptor always supplies its tool
# map; only a launchable one lets an agent launch its T3 driver.

def str: type == "string" and length > 0;
def strs: type == "array" and all(.[]; str);
def tool_entry: type == "object" and (.claude | str)
    and ((has("keys") | not) or ((.keys | type) == "object" and all(.keys[]; str)));
def shape: type == "object" and (.id | str)
    and (.t3 | type) == "object" and (.t3.driver | str) and (.t3.instance_ids | strs)
    and (.tool_map | type) == "object" and (.tool_map.tools | type) == "object"
    and all(.tool_map.tools[]; tool_entry)
    and (.token_paths | strs)
    and all(.token_paths[]; startswith("~/") or startswith("*/"))
    and (.complete | type) == "boolean";
def launchable: .complete
    and ([.hook_config, .adapter, .deny_dialect, .egress_provider, .lane, .quota_source] | all(.[]; str))
    and (.event_map | type) == "object" and (.event_map | length) > 0;

[$ARGS.named | to_entries[] | select(.key | endswith(".json")) | .key as $f | .value as $text
    | {file: $f, doc: (try ($text | fromjson) catch error("\($f) is not one JSON document"))}] as $all
| ([$all[] | select(.file == "harness.schema.json") | .doc["x-listed-harnesses"]? | select(strs and length > 0)]
    | if length == 1 then .[0] else error("harness.schema.json is missing or names no harness list") end) as $listed
| [$all[] | select(.file != "harness.schema.json")] as $files
| [$files[] | .file as $f | .doc
    | if shape and (.id + ".json") == $f then . + {launchable: launchable} else error("\($f) is malformed") end] as $reg
| ($listed - [$reg[].id]) as $gone
| if ($gone | length) > 0 then error("no descriptor for the listed harness \($gone[0])") else . end
| if ([$reg[].t3.driver] | length) != ([$reg[].t3.driver] | unique | length)
    then error("two descriptors name the same T3 driver") else . end
# A token path is matched as a shell glob on the path tail, lower-cased as the secrets guard folds paths.
| if $ARGS.named.out == "tokens"
    then $reg[].token_paths[] | ltrimstr("~") | if startswith("/") then "*" + . else . end | ascii_downcase
    else $reg end
