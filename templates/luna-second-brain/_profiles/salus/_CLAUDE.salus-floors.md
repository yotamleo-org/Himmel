<!-- salus-posture-floors -->
### Posture A — which egress floor loads for which harness
This supersedes the "Posture A — egress floor" bullets above on which floor loads.

| Harness | Egress floor in this vault |
|---|---|
| Claude sessions | `.claude/hooks/block-cloud-egress.sh`: run Claude from the vault (`cwd = the vault`) so it loads. |
| Antigravity (`agy`) sessions | himmel's `block-agy-salus-egress.sh`, loaded from the user-scope backstop. No backstop means no floor: do not run agy here without it. |
| Any other harness | No egress floor in this vault. |

List this vault in `~/.config/claude-glm/phi-roots` as well, so its salus scope does
not rest only on the `.salus` marker inside the vault.
