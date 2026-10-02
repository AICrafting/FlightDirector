# Finishes the adapters' base objects for `issues list|get|comments --json` (#253).
#
# The adapters map each backend onto one base shape (adapters/_json.sh); this adds
# what only the dispatcher knows, the same way on every backend:
#   status     the status ROLE the issue's labels carry, through the selected tracker's
#              label map ($labels.status, in map order) — null when none does. Kept on
#              closed issues too: `state` says open/closed, `status` says where it got to.
#   signature  the trailing flight signature the dispatcher appended when writing the
#              body, split out of `body` into {plugin, version, model} (null if absent)
#   tracker / qualified   the named-tracker identity ($tracker is the ref; empty on a
#              pre-schema-3 config, where both are null)
# and fixes key order so every backend serialises identically.
#
# Invoked as: jq -c --arg mode list|get|comments|comment --arg tracker REF --argjson labels MAP
# Contract: ../references/json-output.md.

def tracker_or_null: if $tracker == "" then null else $tracker end;

# A Jira key (PROJ-7) qualifies as REF-7, exactly as `issues resolve` does.
def qualified_id:
	if $tracker == "" then null
	else "\($tracker)-\(.number | tostring | split("-") | last)"
	end;

def status_role:
	. as $names
	| [($labels.status // {}) | to_entries[] | select(.value | type == "string")
	   | select(.value as $v | $names | index($v) != null) | .key]
	| first // null;

# Same three shapes the dispatcher's signer recognises and replaces (blank lines
# around the rule allowed: Jira's ADF shim renders blocks a blank line apart; and
# CRLF line ends, which GitHub's web editor writes when a body is edited there):
#   ---\n🤖 via FlightDirector:<plugin>@<version>[ with <Model/ver>]
#   ---\nvia FlightDirector:…   and   ---\nFlightDirector:…   (older plugins)
def split_signature:
	if (.body | type) != "string" then . + {signature: null}
	else
		([.body | capture("^(?<text>[\\s\\S]*?)\\s*\\n---[ \\t\\r]*\\n\\s*(?:(?:🤖 )?via )?FlightDirector:(?<plugin>[A-Za-z0-9._-]+)@(?<version>[^\\s]+?)(?: with (?<model>[^\\n]+?))?\\s*$")] | first) as $m
		| if $m == null then . + {signature: null}
		  else . + {body: $m.text, signature: {plugin: $m.plugin, version: $m.version, model: $m.model}}
		  end
	end;

def finish_issue:
	split_signature
	| {
		number: (.number | tostring), tracker: tracker_or_null, qualified: qualified_id,
		title, state, status: (.labels | status_role), labels,
		author, created, updated, comments, url, body, signature
	  };

def finish_comment:
	split_signature
	| {id: (.id | tostring), author, created, updated, url, body, signature};

# Newest created first; issue number breaks ties so the order is total and stable.
def newest_first:
	sort_by([(.created // ""), (.number | tonumber? // 0)]) | reverse;

if $mode == "list" then
	{issues: (.issues | map(finish_issue) | newest_first), truncated: (.truncated // false), total: (.total // null), errors: []}
elif $mode == "get" then
	finish_issue
elif $mode == "comments" then
	map(finish_comment)
elif $mode == "comment" then
	finish_comment
else
	error("issue-json: unknown mode \($mode)")
end
