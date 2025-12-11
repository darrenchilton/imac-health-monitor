# Tailscale Setup for SNiMac  
This document provides the complete setup and troubleshooting reference for using Tailscale on **SNiMac**, including:

- Installation and activation
- macOS GUI requirements
- Tailnet-based SSH, SMB, and Screen Sharing
- All issues encountered during installation
- SSHFS/FUSE mount troubleshooting
- Script locations and aliases unique to this environment

This is the definitive, combined technical guide for SNiMac’s Tailscale deployment.

---

# 1. Overview

Tailscale creates a private, encrypted mesh network connecting approved devices.  
After activation, SNiMac receives a private IP such as:

```text
100.x.x.x
```

and supports:

- SSH over Tailscale (no router forwarding)
- SMB file sharing across Tailnet
- macOS Screen Sharing (VNC) over Tailnet
- Eliminating public SSH exposure

macOS requires a **local GUI login** for first-time Tailscale activation.

---

# 2. Installation (Completed)

Tailscale was installed from the official macOS package:

```text
Tailscale-1.90.9-macos.pkg
```

This created:

```text
/Applications/Tailscale.app
/Applications/Tailscale.app/Contents/MacOS/Tailscale   (CLI binary)
```

The CLI binary works **after** local GUI login is completed.

---

# 3. macOS-Specific Behaviors Observed

## 3.1 CLI silently hangs before GUI login  

Running:

```bash
sudo "/Applications/Tailscale.app/Contents/MacOS/Tailscale" up
```

resulted in **no output**, hanging until `Ctrl+C`.

Why:

- Tailscale requires GUI login for initial authentication  
- CLI communicates with a user-space agent  
- No GUI = silently blocked agent calls  

Fix:

- Perform the first login locally on SNiMac.

---

## 3.2 Gatekeeper & permissions checks performed

We verified the app bundle was not quarantined:

```bash
sudo xattr -dr com.apple.quarantine "/Applications/Tailscale.app"
sudo chmod +x "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
```

These steps did not resolve CLI hang → confirming GUI login is required.

---

# 4. REQUIRED Local Activation Steps

On the physical iMac:

1. Log in to the macOS user session.
2. Open:
   ```text
   /Applications/Tailscale.app
   ```
3. Allow the browser login window to open.
4. Sign in with your Tailscale account.
5. Approve SNiMac in the Tailscale admin panel.

After this, Tailscale’s CLI and service operate normally from SSH.

---

# 5. Post-Login Verification (via SSH)

Once activated:

```bash
tailscale status
tailscale ip
```

Expected output:

```text
SNiMac   online
100.x.x.x
```

SSH can now use the Tailnet address exclusively.

---

# 6. SSH Over Tailscale

Preferred connection:

```bash
ssh slavicanikolic@<tailscale-ip>
```

Benefits:

- No router port forwarding  
- No exposure to the Internet  
- Works from any network  
- End-to-end WireGuard encryption  

---

# 7. SMB File Sharing Over Tailscale

On SNiMac:

```text
System Settings → General → Sharing → File Sharing
```

From your MacBook:

1. Install Tailscale  
2. Finder → Command + K  
3. Connect with:
   ```text
   smb://<tailscale-ip>
   ```

Authenticate using your SNiMac macOS account.

---

# 8. Screen Sharing (VNC) Over Tailscale

Enable:

```text
System Settings → General → Sharing → Screen Sharing
```

Then connect with:

```text
vnc://<tailscale-ip>
```

---

# 9. NAT Loopback Limitation (Encountered)

Inside home network, this failed:

```bash
ssh -p 22222 slavicanikolic@snimac.ddns.net
```

Error:

```text
kex_exchange_identification: read: Connection reset by peer
```

Cause:  
**The Verizon CR1000A router does not support NAT loopback.**

Correct usage:

- Inside LAN:
  ```bash
  ssh slavicanikolic@192.168.1.155
  ```
- Outside LAN / LTE:
  ```bash
  ssh -p 22222 slavicanikolic@snimac.ddns.net
  ```

Tailscale eliminates this entirely.

---

# 10. SSHFS Mount & FUSE Debugging (Full Notes)

During testing, the mountpoint:

```text
/Users/Shared/SNiMac
```

became corrupted, returning:

```text
Input/output error
```

### Diagnosis

```bash
mount | grep SNiMac
diskutil unmount force /Users/Shared/SNiMac
sudo umount -f /Users/Shared/SNiMac
```

Once unmounted, the path returned to normal:

```bash
ls -ld /Users/Shared/SNiMac
```

### Working SSHFS mount command

```bash
sshfs -p 22222 slavicanikolic@snimac.ddns.net:/ /Users/Shared/SNiMac   -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3
```

After success:

```bash
open /Users/Shared/SNiMac
```

---

# 11. Script Locations & Aliases (Actual Environment)

Your scripts reside here on the **MacBookPro**:

```text
~/snimac-tools/scripts/mount_snimac.sh
~/snimac-tools/scripts/unmount_snimac.sh
```

Aliases in `~/.zprofile`:

```bash
alias mount_snimac="~/snimac-tools/scripts/mount_snimac.sh"
alias unmount_snimac="~/snimac-tools/scripts/unmount_snimac.sh"
alias snimac_open="mount_snimac && open /Users/Shared/SNiMac"
```

Notes:

- These aliases exist on the **MacBookPro**, not on SNiMac  
- Use them only when your shell prompt is:
  ```text
  (base) testing@macbookpro ~ %
  ```

---

# 12. After Tailscale Is Fully Operational

You may safely disable public SSH:

- Remove the port-forward rule:
  ```text
  22222 → 192.168.1.155:22
  ```
- Update workflows to:
  ```bash
  ssh slavicanikolic@<tailscale-ip>
  ```
  ```text
  smb://<tailscale-ip>
  vnc://<tailscale-ip>
  ```

This completes the zero-trust remote access posture.

---

# 13. Troubleshooting Checklist (All Issues Merged)

### CLI hangs

- GUI login not completed  
- Launch Tailscale.app locally  

### `tailscale: command not found`

Use full path:

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale
```

### FUSE mount errors (I/O error)

```bash
diskutil unmount force /Users/Shared/SNiMac
sudo umount -f /Users/Shared/SNiMac
```

Then recreate if needed:

```bash
sudo mkdir -p /Users/Shared/SNiMac
sudo chown "$USER":staff /Users/Shared/SNiMac
```

### Cannot SSH to ddns inside LAN

Router lacks NAT loopback → use LAN IP:

```bash
ssh slavicanikolic@192.168.1.155
```

### Termius key imported but no passphrase prompt

Termius prompts **only during connection**, not during import.  
If SSH from Mac prompts for a passphrase and Termius does not, confirm:

- The correct private key file was imported (not `.pub`)
- The key actually has a passphrase by running:
  ```bash
  ssh-keygen -y -f ~/.ssh/id_ed25519
  ```
  and checking whether it asks for one.

---

# 14. Summary

Once local GUI login is completed:

- Tailscale provides secure remote access via private 100.x IP  
- SSH, SMB, and VNC work without exposing ports  
- sshfs mountpoints work cleanly when not corrupted  
- Troubleshooting steps are documented here for future reference  

This single file replaces all earlier fragments and notes for Tailscale on SNiMac.
