

─── ⋆⋅☆⋅⋆ ─── ✈️ ⋆⋅☆⋅⋆ ─── 🌸✨
⋆｡ﾟ✶°✈️°✶｡ﾟ⋆ 🌈💖
─── ⋆⋅☆⋅⋆ ─── ✈️ ⋆⋅☆⋅⋆ ─── 🌸✨


# 🌸✨ ADSB.im Proxmox Helper Script ✨🌸  

<p align="center">
  <img src="https://img.shields.io/github/stars/ThatGirl-me/ADSB.im-Proxmox-Helper-script?color=pink&style=for-the-badge&logo=github&label=Stars%20%E2%AD%90" alt="Stars"/>
  <img src="https://img.shields.io/github/downloads/dirkhh/adsb-feeder-image/total?color=ff69b4&style=for-the-badge&logo=cloudsmith&label=Image%20Downloads%20%F0%9F%8C%B8" alt="Downloads"/>
  <img src="https://img.shields.io/badge/Cuteness-Overload-%23ffb6c1?style=for-the-badge&logo=sparkles" alt="Cuteness Overload"/>
  <img src="https://img.shields.io/badge/ADS--B.im-Feeder-%23ff69b4?style=for-the-badge&logo=aircanada" alt="ADS-B.im"/>
</p>

---

Hiyaa~! 💖 ⸜(｡˃ ᵕ ˂ )⸝♡

Do you wanna set up your very own ADSB.im feeder VM in Proxmox… but like… *without all the terminal typing*?  
Well, look no further because THIS ✨magical✨ helper script will do all the boring stuff for you while you sip tea and twirl your hair~ ☕💕

---

## 🦄💻 What does it do?
- 💾 Downloads the official **ADSB.im VM image**  
- 📦 Unpacks it all nice & neat  
- 🖥️ Creates a brand new **Proxmox VM** (with defaults that *just work*)  
- 🪄 Adds your disk to the storage you pick (local, ZFS, whatever~!)  
- 🧙 Uses a **sweet GUI (whiptail)** so you just click around ✨👑

---

## 🌈 How to use it? (sooo easy~!)

1. Open your **Proxmox terminal** (yes babe, the black scary window 💻 but don’t worry~).
2. Copy–paste this single magical spell ✨:
```
bash -c "$(wget -qLO - https://raw.githubusercontent.com/ThatGirl-me/ADSB.im-Proxmox-Helper-script/main/vm/adsb-im-vm.sh)"
```

- A cute blue menu will pop up 💙💙 just follow the sparkles 🌸

- Pick your storage

- Decide if you want simple defaults (🥱) or advanced custom stuff (✨fancy✨)

- Confirm the summary 💌

- And **boom!** You’ve got your very own ADSB.im VM 🎉


**🍓 Requirements**

- A working Proxmox VE 

- whiptail installed (script will try to install it for you if missing!)

- An internet connection to fetch the image ✨🌐

**💻✨ Preview (it looks sooo cute! 💕)**
```
┌───────────────────────────── ADSB.im installer ───────────────────────────────┐
│                                                                               │
│   Choose mode:                                                                │
│                                                                               │
│       (*) simple     – Use sensible defaults (2 cores, 1GB RAM, 16GB disk)    │
│       ( ) advanced   – Customize everything ✨           				        │
│                                                                               │
│                          < Ok >                             < Cancel >        │
└───────────────────────────────────────────────────────────────────────────────┘

┌───────────────────────────── ADSB.im installer ───────────────────────────────┐
│                                                                               │
│   Select storage for your VM disk:                                            │
│                                                                               │
│       local        – Directory storage (/var/lib/vz)   avail: 60GB            │
│       																        │
│                                                                               │
│                          < Ok >                             < Cancel >        │
└───────────────────────────────────────────────────────────────────────────────┘

┌───────────────────────────── ADSB.im installer ───────────────────────────────┐
│                                                                               │
│   Confirm these ✨magical✨ settings:                                        │
│                                                                               │
│       VMID      : 103                                                         │
│       Name      : adsb-im                                                     │
│       Storage   : local                                                       │
│       Disk      : adsb-im-x86-64-vm.qcow2 → 16G (scsi)                        │
│       CPU/Mem   : 2 cores / 1024 MB                                           │
│       Bridge    : vmbr0                                                       │
│       Firewall  : 1                                                           │
│       Autostart : yes                                                         │
│                                                                               │
│                                                                               │
│                                                                               │
│                          < Yes, do it! 💖 >    < No!!>		                │
└───────────────────────────────────────────────────────────────────────────────┘
```
**💕 Credits**

This helper script is just a sugary wrapper 🎀

All the real magic ✨ comes from the **ADSB.im project** and the awesome feeder image by **Dirk**:

**🌍 ADS-B.im homepage: https://adsb.im/home**

**🛠️ Feeder image repo: dirkhh/adsb-feeder-image**

**💖 Huge thanks to them for making this possible 💖**


Made with waaay too much ✨ love ✨ and not enough Redbull ☕ by **ThatGirl-me.**

Special thanks to all the cutie pies feeding the skies 🛫🌍✨



─── ⋆⋅☆⋅⋆ ─── ✈️  ⋆⋅☆⋅⋆ ───  🌸✨  ⋆｡ﾟ✶°✈️°✶｡ﾟ⋆   🌈💖  ─── ⋆⋅☆⋅⋆ ─── ✈️  ⋆⋅☆⋅⋆ ───  🌸✨  


🌸 Warning: May cause nausea due to extreme cuteness overload.
Use at your own risk! (✿◠‿◠)
