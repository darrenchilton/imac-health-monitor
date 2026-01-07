# System Notes & Historical Record

This document contains the full system history, version changes, debugging investigations, incident logs, and future enhancements for the iMac Health Monitoring System.

*2025-12-08: Rotated Airtable PAT, updated scopes to include System Health base (read/write records).*

---

# 1. Version History

(From original README; preserved verbatim for accuracy.)

## v3.4.0 (2025-12-09) — RTC Clock Drift Monitoring
- NEW: RTC clock drift detection via NTP offset check
- Clock status categorization (Healthy/Warning/Critical)
- rateSf clamping error detection (24h window)
- Integrated into health scoring and severity assessment
- Three new Airtable fields: Clock Drift Status, Clock Offset (seconds), Clock Drift Details
- Addresses correlation between clock drift and GPU timeouts/watchdog panics

## v3.2.4 (2025-12-06) — Reachability & Unclassified Error Attribution
- sshd/screen sharing/tailscale diagnostics  
- Remote-access residue detection  
- unclassified_top_errors to explain error gaps  
- No threshold changes  

## v3.2.3 (2025-12-01) — GUI App Detection Rewrite
- Replaced AppleScript app detection with process scan  
- Eliminated false “No GUI apps detected” issues  
- Improved reliability and performance  

## v3.2.3 (2025-12-02) — Documentation Updates  
- System Modifications Log added  
- Messages.app wake freeze investigation documented  

## v3.2.0 (2025-11-27) — Threshold Calibration
- Statistical thresholds (281 samples)  
- Eliminated false “Critical” alerts  
- Three-tier health scoring  

## v3.1.2 (2025-11-25) — Memory Pressure Fix  
- Corrected inverted memory pressure calculation  

## v3.1.1 (2025-11-22) — Lock File & User Tracking  
- Added lock file protection  
- User session tracking, application inventory  
- VMware monitoring  
- Crash detection improvements  

## v3.1 (2025-11-22)
- Lock file  
- Legacy software detection  
- Resource hog detection  
- New Airtable fields  

## v3.0 (2025-11-19)
- GPU freeze detection  
- Boot device fixes  
- Raw JSON payload storage  

## v2.2 (Previous)
- Noise-filtered logs  
- Burst-aware error detection

- ## 2026-01-06 — GPU instability instrumentation (baseline phase complete)

Status:
- GPU-related monitoring instrumentation added in a minimal, low-risk manner.
- System returned to a clean, stable baseline after implementation.
- No ongoing debugging or experimental hooks left in production code.

New fields introduced (Airtable schema created up front):
- gpu_timeout_1h
- gpu_reset_1h
- gpu_last_event_ts
- gpu_last_event_excerpt
- windowserver_errors_1h (placeholder)
- gpu_panic_or_watchdog_24h (placeholder)

Implementation details:
- gpu_timeout_1h:
  - Counts GPU timeout-style messages observed in unified logs over the last 1 hour.
- gpu_reset_1h:
  - Counts GPU reset / restart messages observed in unified logs over the last 1 hour.
- gpu_last_event_ts / gpu_last_event_excerpt:
  - Populated only when gpu_timeout_1h > 0.
  - Remain null/blank under normal operation.

Design constraints:
- No new background daemons introduced.
- No GPU polling or profiling.
- No kexts or invasive diagnostics.
- All signals derived from existing log buffers already collected by the monitor.

Validation:
- Fields confirmed to flow correctly to Airtable.
- Typical steady-state values are zero.
- Blank fields are intentional and indicate no GPU-related events.

Not yet implemented (by design):
- windowserver_errors_1h population
- gpu_panic_or_watchdog_24h population
- Any causal or lead/lag correlation logic

Next phase (explicitly deferred):
- Temporal correlation between GPU events, WindowServer errors, reboots, and watchdogs.
- Focus will be on ordering and co-occurrence, not raw volume.

System state after change:
- LaunchDaemon running stably.
- Locking verified.
- No duplicate runs.
- Considered a clean baseline for future GPU/WindowServer causality analysis.


---

# 2. System Modifications Log & Incident Timeline


## 2026-01-07 — Airtable Gaps Due to Empty Date Field (Resolved)

**Symptom**
- Airtable time-series gap (~01:40–07:35 local)
- LaunchDaemon executed on schedule
- No system crash, reboot, or sleep during the gap

**Cause**
- Field involved: `gpu_last_event_ts`
- When no GPU timeout/reset events occurred, the script previously sent:
  ```json
  "gpu_last_event_ts": ""
  ```
- Airtable Date fields cannot parse empty strings and returned:
  `422 INVALID_VALUE_FOR_COLUMN`
- Entire record was rejected, creating silent data gaps despite successful script execution.

**Contributing factors**
- launchd logs contained both successful and failed uploads, masking the issue.
- Env file path mismatch (`/etc/imac-health-monitor.env` vs `/etc/imac_health_monitor.env`) temporarily caused exit code 1 during recovery.
- A stale lock directory (`/tmp/imac_health_monitor.lockdir`) intermittently blocked retries while debugging.

**Resolution**
- `gpu_last_event_ts` is now conditionally added only when a valid timestamp exists.
- Empty or whitespace-only values are treated as null and omitted.
- Env file path corrected to match script expectations.
- Stale lock directory cleared.

**Verification**
- Airtable HTTP 200 responses observed.
- Records successfully created after fix.
- `launchctl print` reports `last exit code = 0` after completion.

**Design rule going forward**
> Never send empty strings to Airtable Date fields. Omit the field or send `null`.


## 2025-12-16 — Crash on Apple-only RAM; switched to OWC-only configuration

At approximately **12:30 PM local time**, the system experienced another crash while running on
**Apple OEM memory only (4 GB + 4 GB, 8 GB total)**.

Actions taken immediately after the crash:
- Removed both Apple 4 GB DIMMs
- Installed **OWC-only matched pair**:
  - 32 GB + 32 GB (Model: OWC2666DDR4S32G)
  - Total: **64 GB**
- Verified by macOS: 64 GB installed, 2 slots populated, 2 slots empty

Interpretation:
- Persistence of instability on Apple-only RAM rules out Apple DIMMs as the sole failure cause.
- Issue is unlikely to be simple third-party RAM incompatibility or mixed-capacity configuration alone.
- Findings suggest either:
  - a memory slot / IMC / logic board–level issue, or
  - a separate hardware domain (SMC / RTC / Thunderbolt / external SSD) that is sensitive to idle background activity.

Next steps:
- Continue monitoring on OWC-only 64 GB configuration.
- Focus on:
  - recurrence of kernel/network error storms
  - idle-time crashes
  - shutdown cause codes
- If instability persists, RAM will be considered a secondary factor rather than root cause.

- Addendum:
- When installing the OWC 32 GB + 32 GB pair, the DIMMs were placed in **different memory slots** than the Apple 4 GB DIMMs previously occupied (slot layout changed).
- This introduces an implicit slot/path isolation component to the test (slot-specific fault vs DIMM-specific fault).



## 2025-12-15 — PRAM Reset Performed
- Performed PRAM reset at 5:30 AM EST (Command-Option-P-R on startup)
- Action taken to address persistent hardware timing issues
- Following up on SMC reset from 2025-12-11
- Monitoring system stability, clock drift, and GPU timeout events

- ## 2025-12-15 — Suspected RAM instability (mixed-capacity DIMMs)

System identified with mixed memory configuration on iMac19,1 (2019):
- 32 GB + 32 GB + 4 GB + 4 GB (72 GB total, all slots in use).
- Mixed-capacity DIMMs observed under macOS Sonoma.

Recurring crash pattern shows:
- Repeated “Monitor Closely / Critical” events.
- Kernel- and network-dominant error streams.
- Crashes occurring while system is idle (console idle for days), not user-driven.
- Highly similar pre-crash signatures across multiple dates.

Assessment:
- Mixed-capacity RAM on this model/OS is a plausible source of marginal hardware instability.
- Configuration may have been previously tolerated but degraded under Sonoma or with aging hardware.

Planned actions:
- Leave current configuration in place temporarily to gather additional baseline telemetry.
- Later today, remove the two 4 GB DIMMs and test system with matched 32 GB + 32 GB configuration (64 GB total).
- Monitor error rate, crash frequency, and idle stability post-change for comparison.

Status:
- PRAM/NVRAM reset completed earlier today.
- RAM removal pending; change not yet applied at time of this entry.

## 2025-12-15 — RAM configuration change (OWC DIMMs removed)

At approximately **11:00 AM EST**, the following hardware change was performed:

- **Removed:** two 32 GB third-party DIMMs  
  - Model: **OWC2666DDR4S32G**
- **Retained:** two original Apple 4 GB DIMMs
- **Resulting configuration:** 4 GB + 4 GB (8 GB total, Apple OEM)
- All other hardware unchanged
- System continues to boot from external Thunderbolt 3 SSD (SanDisk PRO-G40)

Purpose:
- Isolate suspected RAM instability by removing third-party, high-capacity DIMMs.
- Establish whether crashes and sustained kernel/network error storms persist on known-good Apple OEM memory.
- Create a clean control configuration before re-introducing larger matched modules.

Notes:
- This configuration is intentionally memory-constrained and not intended for long-term use.
- Performance degradation is expected; stability is the sole metric under evaluation.
- This supersedes the previously planned 64 GB matched-pair test, which may be revisited depending on results.

Monitoring status:
- Health monitor active
- **11:00 AM EST** marks the definitive before/after boundary for log and trend analysis.
- Post-change telemetry will be compared against:
  - Pre-change baseline
  - Known failure windows (e.g., Dec 14 escalation period).




- ## 2025-12-14 — Pre-crash error storm (idle console), network+kernel dominant

Crash occurred shortly after: Monitor Closely-Critical (Dec 14, 2025 9:17 PM).
In the 60 minutes prior, Error Count showed the sharpest observed step-up at 20:49 (Δ ≈ +34,638 vs prior sample).
Pre-crash error-stream mix was dominated by error_network_1h (8,383) and error_kernel_1h (5,147), with smaller Spotlight/iCloud components.
Pattern matches multiple prior “Critical” events (cosine similarity ≈ 0.993–0.997), typically network-heavy (>50% share), suggesting a recurring failure mode rather than a one-off user-triggered incident.

Notes: sampling is sparse in the final hour (only 2 records pre-21:17), so finer-grained inflection timing cannot be resolved from this dataset.


## 2025-12-11 — SMC Reset Performed
- Performed SMC reset this morning (unplugged power for 15 seconds)
- Action taken to address RTC clock drift and rateSf clamping issues
- Monitoring effectiveness over next 48-72 hours
- Initial post-reset readings: clock offset 0.008-0.03s (good), rateSf events still elevated at 3-8/hour

## 2025-12-10 — Abrupt Reboot & Health Monitor / Airtable Fixes

* **Event:** Unexpected system reboot at ~2025-12-10 20:02.

  * `last reboot` shows: `reboot time Wed Dec 10 20:02`.
  * Unified log (`log show`) reports: `(AppleSMC) Previous shutdown cause: 3` near 20:02.
  * No corresponding `*panic*.panic` files found in `/Library/Logs/DiagnosticReports` or `~/Library/Logs/DiagnosticReports`.
* **Interpretation:**

  * Shutdown cause `3` indicates an abrupt restart / hard reset category (not a clean menu-driven “Restart…”).
  * Absence of a `.panic` file suggests either a low-level reset without a formal kernel panic dump, or a crash early enough that the panic report wasn’t written to disk.
  * Most likely: sudden reset / power-like event rather than a normal software restart.
* **User-impact / symptoms:**

  * GUI user session was logged out; per-user LaunchAgents (including `com.slavicany.imac-health-monitor`) disappeared from `launchctl list`.
  * SSH key agent state was lost; subsequent SSH connections prompted for key passphrase again (expected after session teardown).
  * Health monitor appeared “not running” when inspected over SSH because the GUI login session (and its `gui/$UID` launchd domain) was gone.
* **Health monitor issues uncovered during investigation:**

  * Old log entries showed `./imac_health_monitor.sh: syntax error near unexpected token '<<<<<<< HEAD'` and `[[: 0 0: syntax error in expression (error token is "0")` from a previous state where merge-conflict markers existed in the script.

    * Current script passes `bash -n` and runs cleanly; historical errors left in `imac_health_monitor.launchd.err` were confusing the picture.
  * Airtable began returning `422 INVALID_REQUEST_MISSING_FIELDS` with message `"Could not find field \"fields\" in the request body"`.

    * Root cause: typo in the jq JSON template, missing opening quote on the new `"Previous Shutdown Cause"` field key:

      * Broken: `Previous Shutdown Cause": $previous_shutdown_cause,`
      * Fixed: `"Previous Shutdown Cause": $previous_shutdown_cause,`
    * This produced malformed JSON, so Airtable could not see the top-level `"fields"` object.
* **New telemetry added:**

  * **Previous Shutdown Cause capture:**

    * Script now queries unified logs for the last shutdown cause and sends it to Airtable as `"Previous Shutdown Cause"`.
    * Implementation: `log show` over a wider time window with `grep "Previous shutdown cause"` and `tail -1` to capture the most recent value.
    * In Airtable, a formula field `Shutdown Cause (Text)` maps numeric codes:

      * `5` → “Normal software restart”
      * `3` → “Abrupt restart / hard reset”
      * `0` → “Power loss / sudden off”
      * `14` → “Thermal protection shutdown”
      * Unknown/other values → `"Other (X)"` or left blank if there is no value.
  * **Log collection observability:**

    * `safe_log()` now writes debug lines around each `log show` invocation (start, timeout, completion) for both `1h` and `5m` windows.
    * Additional debug line added around the heavy `LOG_1H`/`LOG_5M` parsing section to distinguish “slow `log show`” vs “slow grepping/parsing of that data.”
* **Performance observations:**

  * `log show --style syslog --last 1h` can take several minutes on this system after heavy activity (especially post-crash), causing noticeable pauses at `Starting log collection (1h window)` and during the parsing block.
  * `safe_timeout` is currently set to 300 seconds for the 1h window; when it times out, the monitor falls back to zeroed metrics and `"Log collection timed out"` to avoid blocking indefinitely.
* **Status / follow-up:**

  * Health monitor LaunchAgent is confirmed to load and run correctly when the GUI user is logged in; absence from `launchctl list` when logged out is expected behavior for a per-user LaunchAgent.
  * `Previous Shutdown Cause` now flows into Airtable and will aid in classifying future reboots (normal vs abrupt vs thermal/power).
  * If shutdown cause `3` recurs frequently, this will be correlated against:

    * Existing RTC clock drift issues and `Wall Clock adjustment detected` messages.
    * GPU timeouts, watchdog events, and external SSD behavior.
  * For now, event is logged as **“Abrupt reboot with shutdown cause 3, no panic file”** and monitored alongside prior RTC and hardware concerns.


## 2025-12-09 — RTC Clock Drift & Potential Hardware Issue Detected
- Discovered persistent "Wall Clock adjustment detected" warnings in `log show` output
- Investigation revealed significant RTC clock drift: ~45-54 ppm (gains 4-5 seconds/day)
- NTP making corrections every 15-20 minutes (offset ~0.47 seconds)
- Clock drift correlates with:
  - GPU timeout events (Dec 7, Dec 3, Nov 23)
  - Watchdog panic (Dec 7)
  - Persistent trustd malformed anchor errors
  - External SSD I/O timing issues
- **Hypothesis**: Low-level SMC/motherboard hardware issue affecting system timing, cascading into GPU coordination problems, external SSD I/O delays, and security framework errors
- **Observation**: Clock drift improved spontaneously from +0.47s to +0.057s without intervention (intermittent issue confirmed)
- **Action Plan**: 
  1. Perform SMC reset
  2. Monitor if clock drift, GPU timeouts, and watchdog panics cease
  3. If symptoms persist: Apple hardware service likely needed (internal drive failure + clock drift suggests broader hardware issues)
- **Note**: Cannot test internal drive boot (internal drive not bootable)
- **Implementation**: Added v3.4.0 clock drift monitoring to health monitor
  - Real-time NTP offset tracking
  - rateSf clamping error detection
  - Health scoring integration
- Status: **Monitoring in production** - clock drift tracking active, SMC reset pending

## 2025-12-07 — Watchdog Panic & trustd Errors
- Captured watchdog panic (bug_type 210)  
- Persistent trustd malformed anchor errors across all users  
- Investigated: no GPU/WindowServer signals  
- External SSD considered a contributing factor  
- Interim mitigations: disable Chrome GPU accel, daily restarts, disk checks  

## 2025-12-06 — iCloud Sync Spike Isolation Test
- Investigated evening/morning error spikes  
- Disabled iCloud services to isolate CloudKit as potential cause  
- Plan: compare error deltas post-disable  

## 2025-12-04 — Freeze Correlated With Spotlight/PDF Indexing Storm
- Unresponsive system ~08:30 AM  
- Spotlight indexing spike observed in metrics  
- Disabled Spotlight indexing on Data volume  
- Monitoring for recurrence  

## 2025-12-03 — Remote Access Outage / PDF Render Storm
- SSH + Screen Sharing unreachable despite Tailscale online  
- GUI hung; force quit needed  
- Observed multiple CGPDFService workers  
- Removed AnyDesk residues  
- Upgraded monitor to v3.2.4 for visibility  

## 2025-12-02 — Messages.app Wake Freeze Investigation
- GUI frozen after wake; Terminal OK  
- Messages.app crash during wake  
- Root cause: CoreAudio resume blocking WindowServer  
- Disabled Messages notification sounds  
- Testing ongoing  

---

# 3. Debugging Investigations & Findings

## VMware Correlation Study (281 Samples)
Extensive analysis showed VMware Fusion 12.2.4 and legacy guest OSes **not** correlated with system instability.  
- Error rates almost identical with VMware running vs not  
- GPU errors lower when VMware is active  
- Only GPU freeze occurred when VMware was **not** running  
- Conclusion: VMware not a contributor to freezes  

## Spotlight / PDF Indexing Storms
Repeated freezes correlate strongly with Spotlight/QuickLook PDF indexing load.  
- Large spikes in error_spotlight_1h  
- CGPDFService load observed  
- Disabling indexing prevented recurrence in tests  

## CloudKit / iCloud Sync
Evening/morning spikes likely iCloud-related based on deltas seen in error_icloud_1h.  
Testing underway after disabling iCloud sync services.

## trustd Malformed Anchor Errors
Widespread trustd errors appear frequently independent of major instability events.  
Under investigation; may interact with external SSD or corrupted keychain state.

## RTC Clock Drift Investigation (Dec 2025)
Discovered significant Real-Time Clock drift affecting system stability:

**Symptoms**:
- `log show` consistently reports "Wall Clock adjustment detected" warnings
- System clock running 45-54 parts per million (ppm) too fast
- Gains approximately 4-5 seconds per day
- NTP forced to correct by ~0.47 seconds every 15-20 minutes

**Technical Details**:
- `sntp -d time.apple.com` shows consistent +0.469 second offset
- `timed` logs show `rateSf clamped: 1.000046-1.000054` errors
- Frequent `settimeofday` adjustments in system logs

**Correlation Analysis**:
Strong correlation observed between clock drift events and:
1. GPU timeout events ("timed out waiting for X events") - Dec 7, Dec 3, Nov 23
2. Watchdog panic (Dec 7, bug_type 210)
3. trustd malformed anchor errors (ongoing)
4. External SSD I/O coordination issues

**Root Cause Hypothesis**:
Clock drift suggests SMC or motherboard-level hardware issue affecting:
- System interrupt timing → affects GPU coordination
- External Thunderbolt SSD I/O timing
- Security framework certificate/timestamp validation
- Overall system synchronization

**External SSD Boot Interaction**:
External boot device may be exacerbating underlying clock issue:
- I/O latency on external drives affected by interrupt timing
- USB/Thunderbolt controller depends on accurate system clocks
- Clock corrections can confuse external I/O operation timing
- **Critical**: Internal drive not bootable (failed/damaged), forced external boot
- Internal drive failure + clock drift suggests potential systemic hardware degradation

**Testing Protocol**:
1. Perform SMC reset to address hardware clock timing
2. Monitor NTP offset and correction frequency for 24-48 hours
3. Track correlation: does fixing clock drift also eliminate GPU timeouts?
4. ~~Test internal drive boot~~ (not possible - internal drive not bootable)
5. If clock drift persists after SMC reset: hardware service needed - likely motherboard issues

**Severity Assessment**:
Combination of failed internal drive + clock drift + GPU timeouts + watchdog panics suggests **multiple hardware subsystems affected**, potentially:
- Motherboard-level issue affecting both storage controller and RTC/SMC
- Progressive hardware degradation
- May require comprehensive hardware diagnostics beyond just clock/SMC repair

**Expected Outcome**:
If SMC/hardware is root cause, successful repair should eliminate:
- Excessive clock drift (should be <10 ppm)
- GPU timeout events
- Watchdog panics
- Reduction in trustd errors

---

# 4. Troubleshooting & Runbooks

### Sleep/Wake Freeze Protocol
- Test various sleep durations  
- Capture Messages/WindowServer/CoreAudio logs after wake  
- Verify absence/presence of freeze  
- Retest after config changes  

### Spotlight Storm Response
- Disable indexing on Data volume  
- Verify via `mdutil -s`  
- Monitor error_spotlight_1h and system responsiveness  

### Remote Access Failure Runbook
- Check Tailscale direct path  
- Check local TCP ports  
- Examine WindowServer / CGPDFService activity  

### RTC Clock Drift Troubleshooting
**Symptoms**: "Wall Clock adjustment detected" warnings, frequent NTP corrections

**Diagnosis**:
```bash
# Check current clock offset
sudo sntp -d time.apple.com

# Monitor timed daemon for clock adjustments
log show --predicate 'process == "timed"' --last 1h

# Check for rateSf clamping errors
log show --predicate 'process == "timed"' --last 7d | grep "rateSf clamped"
```

**Resolution Steps**:
1. **SMC Reset** (iMac):
   - Shut down iMac completely
   - Unplug power cord from back of iMac
   - Wait 15 seconds
   - Plug power cord back in
   - Wait 5 seconds
   - Press power button to start
   
2. **Verify Clock Stability** (run after 24 hours):
   - Check if NTP offset reduced to <0.1 seconds
   - Verify rateSf errors eliminated
   - Monitor GPU timeout and watchdog panic occurrence

3. **Hardware Service** (if drift persists):
   - Clock drift >40 ppm after SMC reset suggests motherboard/RTC issue
   - Failed internal drive + clock drift indicates broader hardware problems
   - Document symptoms for Apple: internal drive failure + clock drift + GPU timeouts + watchdog panics
   - Recommend comprehensive hardware diagnostics (not just SMC/clock)
   - Consider motherboard replacement may be needed  

---

# 5. Future Enhancements & Roadmap

### Implemented
- ✅ RTC clock drift monitoring (v3.4.0)
- ✅ NTP offset tracking and health integration
- ✅ rateSf clamping error detection

### Planned
- Network connectivity checks  
- Fan speed monitoring  
- Docker container health  
- WiFi RSSI monitoring  
- Airtable schema validation  
- Spotlight early-warning metrics  
- Run-gap detection  
- Spotlight-only error extraction  

### Under Consideration
- Local HTML dashboard  
- Email/Slack alerts  
- Machine learning anomaly detection  
- Historical trend analysis  
- Multi-machine dashboard  
- Per-application resource trends  
- Automated correlation reports  

---

# 6. System Context & Hardware Notes

### Hardware Configuration
- 2019 iMac 27" (Intel i5, 72GB RAM, Radeon Pro 570X)  
- External Thunderbolt 3 SSD boot (SanDisk PRO-G40) - **required due to internal drive issues**
- Internal drive not bootable
- macOS Sonoma 15.7.2  

### Monitoring Challenges Solved
- External SSD quirks  
- Messages wake freeze  
- Spotlight/PDF storms  
- Calibrated macOS log noise  
- VMware stability confirmation  
- Thermal throttling accuracy  
- Memory pressure interpretation
- RTC clock drift detection and tracking  

### Key Learnings
- macOS Sonoma logs ~25K messages/hour under normal conditions  
- Statistical baselines essential for stable thresholds  
- Legacy VMware guests safe  
- External-SSD + Audio resume bugs can wedge WindowServer

- ---

## 2026-01 — LaunchDaemon Migration (Runs Outside User Login)

### Why
- LaunchAgent (gui/$UID) stops when no user session exists (logout, crash, headless operation).
- Needed continuous monitoring across reboots and without an interactive login.

### What changed
- Switched from LaunchAgent to LaunchDaemon:
  - `/Library/LaunchDaemons/com.slavicany.imac-health-monitor.plist`
  - loaded via `launchctl bootstrap system ...`
- Credentials:
  - preferred: `/etc/imac-health-monitor.env` (root-only, 600)
  - fallback: local `.env` for legacy/manual runs
- Logging:
  - launchd stdout: `/var/log/imac_health_monitor.launchd.log`
  - launchd stderr: `/var/log/imac_health_monitor.launchd.err`
  - script debug_log: `/var/log/imac_health_monitor.script.log`
- User LaunchAgent disabled/removed to avoid duplicate Airtable posts:
  - moved `~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist` to `~/Library/LaunchAgents.disabled/`

### Issues encountered and resolved
- `launchctl bootstrap ...` opaque `I/O error` caused by unsupported plist key (`ExitTimeOut`); removed.
- Wrapper script initially swallowed stdout/stderr; daemon updated to execute `imac_health_monitor.sh` directly.
- Stale lock handling caused skipped runs; logic adjusted so stale locks do not block execution indefinitely.
- Debug logging briefly included Airtable token during diagnosis; remove secret output and rotate PAT if needed.

### Current baseline
- System daemon runs cleanly without user login and logs to `/var/log`.
- Ready for GPU-specific instrumentation in a new chat.

