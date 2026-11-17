# Evidence: flights-platform running on EKS

Captured on 2026-11-17 from the live cluster `flights-dev-eks` (eu-north-1) **before** running `DESTROY.md`. Times are UTC unless marked IST (UTC+2).
All the text files start with the command and the capture time.

| File | What it shows |
|---|---|
| `nodes-wide.txt` | `kubectl get nodes -o wide`: 3 nodes, all `m7i-flex.large` (2 system + 1 app) |
| `pods-all.txt` | `kubectl get pods -A`: every pod `Running`, workloads with Istio sidecars (2/2) |
| `argocd-applications.txt` | `kubectl get applications -n argocd`: 17 Applications `Synced` / `Healthy` |
| `pvc-all.txt` | `kubectl get pvc -A`: Postgres (2Gi) and Redis (1Gi) `Bound` on the `gp3` StorageClass |
| `ingress-all.txt` | `kubectl get ingress -A`: the ALB created by the AWS Load Balancer Controller |
| `curl-root.txt` | `GET /` through the ALB: `200`, the `flights-web` page |
| `curl-api-health.txt` | `GET /api/health` through the ALB: `200 {"status":"ok"}` |
| `api-flights.txt`, `api-flights-response.json` | `GET /api/flights?origin=TLV&destination=LHR&date=2027-01-20`: the **original** `200` response from the verification at 20:55:02 UTC (22:55 IST), 123 live offers. Not re-run, see the finding below |
| `api-logs.txt` | Access and warning lines of the `flights-api` pod for every `/flights` request |
| `argocd-apps-1.png`, `argocd-apps-2.png` | ArgoCD UI: 17 Synced, 17 Healthy, 0 OutOfSync/Degraded/Missing |
| `flights-web-provider-error.png` | `flights-web` UI showing the controlled error message (see below) |

## Finding: the flight provider stopped answering from EKS

**What worked.** At 20:55:02 UTC (22:55 IST) the search TLV→LHR 2027-01-20 returned `200` with 123 live offers (`"cached": false`, 0.96 s). The first three: $170 with 1 stop, $196 non-stop, $278 non-stop.

**What changed.** Later the same day, searches started failing with `502 Bad Gateway`. From `api-logs.txt` (the pod logs, UTC):

| Time (UTC) | IST | Search | Result |
|---|---|---|---|
| 20:55 | 22:55 | TLV→LHR 2027-01-20 | `200` (verification) |
| 21:02:37 | 23:02 | TLV→MAD 2026-11-18 | `502`, `fli returned no payload (None)` |
| 21:14:51 | 23:14 | TLV→NRT 2026-12-16 (from the UI) | `502`, `fli returned no payload (None)` |
| 21:17:19 | 23:17 | TLV→LHR 2027-01-20 (**the same search that worked**) | `502`, `fli returned no payload (None)` |

**Probable cause (not verified).** The app gets its data from `fli`, a library that reverse-engineers Google Flights (no official API). Google limits queries coming from datacenter IP ranges, and all traffic from the cluster leaves through the single NAT gateway IP. According to the project owner, the same app works from the homelab, which has a residential IP. The facts above (same query: 200, then 502 with no payload) fit a rate or origin limit on that IP, but nothing here proves it: it was not tested with another egress IP, and the library's behaviour is not documented.

**How the app fails.** In a controlled way. The API answers `502` with a logged warning (`fli search failed ...`), and the UI shows a clear message instead of breaking: *"The flight provider is not responding right now. Please try again in a few minutes."* (`flights-web-provider-error.png`). The rest of the platform stays healthy: the same pods keep serving `/` and `/api/health` with `200`.

**Pending (not part of this work).** The provider is the weak point of any deployment that does not run from a residential IP. Options:
- a provider with an official API and a key (the key would go in Secrets Manager, like the DB credentials);
- caching search results (Redis is already deployed; `cached` is already in the response schema) so repeated searches do not hit the provider.
