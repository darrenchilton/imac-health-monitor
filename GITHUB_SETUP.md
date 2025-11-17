# Setting Up Your GitHub Repository

Quick guide to get your monitoring system on GitHub and running locally.

---

## Part 1: Create GitHub Repository (5 minutes)

### Option A: Via GitHub Website (Easier)

1. **Go to GitHub**
   - Navigate to https://github.com
   - Sign in (or create account if needed)

2. **Create New Repository**
   - Click the **"+"** icon (top right) → **"New repository"**
   - Repository name: `imac-health-monitor`
   - Description: `Automated iMac health monitoring with Airtable tracking`
   - Choose: **Private** (recommended since you'll configure it locally)
   - ✅ Check **"Add a README file"**
   - ✅ Add `.gitignore` → Choose **"None"** (we have our own)
   - Click **"Create repository"**

3. **Get Repository URL**
   - On your new repo page, click green **"Code"** button
   - Copy the URL (should be like `https://github.com/YOUR_USERNAME/imac-health-monitor.git`)

### Option B: Via GitHub CLI (For Command Line Enthusiasts)

```bash
# Install GitHub CLI if needed
brew install gh

# Login to GitHub
gh auth login

# Create repo
gh repo create imac-health-monitor --private --description "Automated iMac health monitoring"
```

---

## Part 2: Push Your Code to GitHub (5 minutes)

### On Your Mac:

```bash
# Navigate to where you downloaded the monitoring files
cd ~/Downloads/imac-health-monitor  # adjust path as needed

# Initialize git repository
git init

# Add all files (except .env which is gitignored)
git add .

# Make initial commit
git commit -m "Initial commit: iMac health monitoring system"

# Connect to your GitHub repository
git remote add origin https://github.com/YOUR_USERNAME/imac-health-monitor.git

# Push to GitHub
git branch -M main
git push -u origin main
```

**✅ Done!** Your code is now on GitHub (without any credentials).

---

## Part 3: Set Up on Your Mac (10 minutes)

Now that it's on GitHub, here's how you'd set it up on your Mac (or any Mac):

### Clone and Configure

```bash
# 1. Clone from GitHub
cd ~/Documents  # or wherever you want to keep it
git clone https://github.com/YOUR_USERNAME/imac-health-monitor.git
cd imac-health-monitor

# 2. Run setup
chmod +x setup.sh
./setup.sh
```

The setup script will:
- Prompt for your Airtable API key and Base ID
- Create `.env` file locally (gitignored)
- Test the connection
- Configure automatic scheduling
- Run a test health check

### Verify Everything Works

```bash
# Check Airtable for a new health record
# View logs
tail -20 ~/Library/Logs/imac_health_monitor.log

# Verify scheduled job
launchctl list | grep healthmonitor
```

---

## Part 4: Update Workflow (Ongoing)

### When You Make Changes

```bash
cd ~/Documents/imac-health-monitor

# Make your changes to scripts
nano imac_health_monitor.sh  # or use your preferred editor

# Test your changes
./imac_health_monitor.sh

# Commit and push to GitHub
git add .
git commit -m "Description of your changes"
git push
```

### When You Want to Update on Your Mac

```bash
cd ~/Documents/imac-health-monitor

# Pull latest changes from GitHub
git pull

# If setup changed, re-run configuration
./setup.sh  # only if needed
```

**Your `.env` file (with credentials) stays safe locally and is never pushed to GitHub!**

---

## Part 5: Advanced - Multiple Machines

If you want to monitor multiple Macs with the same system:

### On Each Additional Mac:

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/imac-health-monitor.git
cd imac-health-monitor

# Run setup (each Mac gets its own .env file)
./setup.sh
```

Each Mac will:
- Use the same scripts from GitHub
- Have its own local `.env` file with Airtable credentials
- Report to the same Airtable base (you'll see which machine by hostname)
- Can be updated independently with `git pull`

---

## Security Checklist

Before pushing to GitHub, verify:

```bash
# Check what will be committed
git status

# Make sure .env is NOT in the list
# Should see: "nothing to commit, working tree clean" or just .sh files

# Double-check .gitignore includes .env
cat .gitignore | grep .env
```

**Expected output:**
```
.env
```

If `.env` appears in `git status`, it means it's about to be committed - **DON'T PUSH!**

```bash
# If .env appears, remove it from staging
git reset HEAD .env

# Make sure .gitignore includes it
echo ".env" >> .gitignore
git add .gitignore
git commit -m "Add .env to gitignore"
```

---

## Common GitHub Operations

### Check Current Status
```bash
git status
```

### View Commit History
```bash
git log --oneline
```

### See What Changed
```bash
git diff
```

### Pull Latest Changes
```bash
git pull
```

### Push Your Changes
```bash
git add .
git commit -m "Your commit message"
git push
```

### Undo Last Commit (if not pushed yet)
```bash
git reset --soft HEAD~1
```

---

## Repository Structure on GitHub

After pushing, your GitHub repo will look like:

```
imac-health-monitor/
├── .gitignore                    ← Protects credentials
├── .env.example                  ← Template (no real credentials)
├── README.md                     ← Main documentation
├── SETUP_GUIDE.md                ← Detailed setup
├── QUICK_REFERENCE.md            ← Daily commands
├── GITHUB_SETUP.md               ← This file
├── imac_health_monitor.sh        ← Main script
├── setup.sh                      ← Setup wizard
└── test_airtable_connection.sh   ← Connection tester

NOT IN REPO (gitignored):
├── .env                          ← Your actual credentials
├── *.log                         ← Log files
└── .DS_Store                     ← macOS files
```

---

## Troubleshooting

### "Permission denied (publickey)" when pushing

You need to set up SSH keys or use HTTPS with a personal access token:

**Quick fix - Use HTTPS:**
```bash
git remote set-url origin https://github.com/YOUR_USERNAME/imac-health-monitor.git
git push
# You'll be prompted for username/password or token
```

**Better solution - Set up SSH keys:**
Follow GitHub's guide: https://docs.github.com/en/authentication/connecting-to-github-with-ssh

### Accidentally committed .env

```bash
# Remove from repo but keep locally
git rm --cached .env
git commit -m "Remove .env from repository"
git push

# IMPORTANT: Rotate your Airtable API key immediately!
# Go to https://airtable.com/account and generate a new key
```

### Can't push changes

```bash
# Pull first, then push
git pull
git push
```

---

## Benefits of This Workflow

✅ **Version Control**: Track all changes to your monitoring scripts
✅ **Backup**: Your code is safely stored on GitHub
✅ **Updates**: Easy to pull changes to any Mac
✅ **Collaboration**: Share with others (they use their own .env)
✅ **Security**: Credentials never leave your Mac
✅ **History**: See what changed and when
✅ **Rollback**: Can revert to previous versions if needed

---

## Quick Reference

| Action | Command |
|--------|---------|
| Clone repo | `git clone https://github.com/YOU/repo.git` |
| Check status | `git status` |
| Pull updates | `git pull` |
| Stage changes | `git add .` |
| Commit | `git commit -m "message"` |
| Push | `git push` |
| View history | `git log --oneline` |

---

## Next Steps

1. ✅ Create GitHub repository
2. ✅ Push your code
3. ✅ Clone to your Mac
4. ✅ Run `./setup.sh`
5. ✅ Verify monitoring is working
6. ✅ Set up Airtable views and automations

**You're all set!** Your monitoring system is now version-controlled on GitHub with secure local credentials. 🎉
