# System Notes & Historical Record

This document contains the full system history, version changes, debugging investigations, incident logs, and future enhancements for the iMac Health Monitoring System.

*2025-12-08: Rotated Airtable PAT, updated scopes to include System Health base (read/write records).*

---

# 1. Version History

(From original README; preserved verbatim for accuracy.)

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

---

# 2. System Modifications Log & Incident Timeline

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

---

# 5. Future Enhancements & Roadmap

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
- External Thunderbolt 3 SSD boot (SanDisk PRO-G40)  
- macOS Sonoma 15.7.2  

### Monitoring Challenges Solved
- External SSD quirks  
- Messages wake freeze  
- Spotlight/PDF storms  
- Calibrated macOS log noise  
- VMware stability confirmation  
- Thermal throttling accuracy  
- Memory pressure interpretation  

### Key Learnings
- macOS Sonoma logs ~25K messages/hour under normal conditions  
- Statistical baselines essential for stable thresholds  
- Legacy VMware guests safe  
- External-SSD + Audio resume bugs can wedge WindowServer  

