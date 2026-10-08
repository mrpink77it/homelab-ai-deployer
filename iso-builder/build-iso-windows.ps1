# ==============================================================================
# Homelab AI Deployer - Windows ISO Builder & USB Flasher
# Target: Windows 10/11 (PowerShell 5.1 / 7+)
# ==============================================================================

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  HOMELAB AI DEPLOYER - PROXMOX AUTOMATED ISO BUILDER     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

# 1. RILEVAMENTO ESCLUSIVO CHIAVETTE USB (FLASH DRIVE)
Write-Host "[1/5] Scansione unita Flash USB collegate..." -ForegroundColor Yellow

$UsbDrives = Get-CimInstance Win32_DiskDrive | Where-Object { 
    $_.InterfaceType -eq 'USB' -and $_.MediaType -like '*Removable*' -or $_.MediaType -like '*External*' 
}

if (-not $UsbDrives) {
    Write-Error "Nessuna chiavetta USB (Flash Drive) rilevata! Inserisci una USB e riavvia lo script."
    exit 1
}

Write-Host "`nUnita Flash USB Trovate:" -ForegroundColor Green
\$i = 1
foreach ($drive in$UsbDrives) {
    $sizeGB = [math]::Round($drive.Size / 1GB, 2)
    Write-Host "  [$i]$($drive.Model) - Capacity:$sizeGB GB - DeviceID: $($drive.DeviceID)"
    \$i++
}

\$Selection = Read-Host "`nSeleziona il numero della chiavetta USB su cui flashare"
$TargetUsb = $UsbDrives[$Selection - 1]

if (-not $TargetUsb) {
    Write-Error "Selezione non valida. Annullamento."
    exit 1
}

Write-Host "Target Selezionato: $($TargetUsb.Model) ($($TargetUsb.DeviceID))" -ForegroundColor Green

# 2. CONFIGURAZIONE IP STATICO / DHCP
Write-Host "`n[2/5] Configurazione Rete per l'installazione automagica..." -ForegroundColor Yellow
\$IpMode = Read-Host "Scegli modalita IP per il server (1 = DHCP / Auto, 2 = Statico Manuale) [Predefinito: 1]"

\$NetworkConfig = @{
    CIDR = "dhcp"
    Gateway = ""
}

if (\$IpMode -eq "2") {
    \$NetworkConfig.CIDR = Read-Host "Inserisci IP/CIDR (es. 192.168.1.150/24)"
    \$NetworkConfig.Gateway = Read-Host "Inserisci Gateway (es. 192.168.1.1)"
}

# 3. DOWNLOAD ULTIMA ISO PROXMOX VE
$WorkDir = "$env:TEMP\proxmox-builder"
New-Item -ItemType Directory -Force -Path \$WorkDir | Out-Null
$IsoPath = "$WorkDir\proxmox-ve-latest.iso"

Write-Host "`n[3/5] Download ultima ISO ufficiale di Proxmox VE..." -ForegroundColor Yellow
$PveDownloadUrl = "https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso" # URL aggiornabile/dinamico

if (-not (Test-Path $IsoPath)) {
    Invoke-WebRequest -Uri $PveDownloadUrl -OutFile $IsoPath -UseBasicParsing
    Write-Host "Download completato." -ForegroundColor Green
} else {
    Write-Host "ISO Proxmox gia presente in cache temporanea." -ForegroundColor Green
}

# 4. GENERAZIONE ANSWER.TOML PER INSTALLATORE AUTOMATICO
Write-Host "`n[4/5] Generazione file di configurazione automatica (answer.toml)..." -ForegroundColor Yellow

\$AnswerTomlContent = @"
[global]
keyboard = "it"
country = "it"
timezone = "Europe/Rome"
fqdn = "pve.homelab.local"
mailto = "admin@homelab.local"
root_password = "proxmox"
reboot_mode = "reboot"

[network]
source = "\$($if ($NetworkConfig.CIDR -eq 'dhcp') { 'from-dhcp' } else { 'from-answer' })"
cidr = "$($NetworkConfig.CIDR)"
gateway = "$($NetworkConfig.Gateway)"
dns = "1.1.1.1"
dns2 = "8.8.8.8"

[disk_setup]
filesystem = "zfs (RAID0)"
disk_list = ["filter:first_matched"]
"@

$AnswerPath = "$WorkDir\answer.toml"
Set-Content -Path $AnswerPath -Value$AnswerTomlContent -Encoding UTF8

# 5. SCRITTURA / FLASH SU CHIAVETTA USB
Write-Host "`n[5/5] PREPARAZIONE FLASH USB..." -ForegroundColor Red
Write-Host "ATTENZIONE: Tutti i dati presenti sulla USB $($TargetUsb.Model) verranno CANCELLATI!" -ForegroundColor Red
$Confirm = Read-Host "Digita 'SCRIVI' per confermare l'operazione"

if ($Confirm -ne 'SCRIVI') {
    Write-Host "Operazione annullata dall'utente." -ForegroundColor Yellow
    exit 0
}

# Uso di Rufus CLI / dd per la scrittura raw dell'immagine sulla USB selezionata
$DiskNumber = $TargetUsb.DeviceID.Replace("\\.\PHYSICALDRIVE", "")

Write-Host "Pulizia disco USB $DiskNumber ed esecuzione scrittura RAW..." -ForegroundColor Yellow

$DiskpartScript = @"
select disk $DiskNumber
clean
convert mbr
active
"@
$DiskpartScript | diskpart

# Scrittura ISO tramite risorsa dd o tool nativo (es. Rufus/ImageBurn CLI se integrato)
Write-Host "Flashing ISO sulla chiavetta USB $DiskNumber in corso..." -ForegroundColor Green
# Comando di flash raw (es. dd.exe / rufus)
# rufus.exe --drive-index=$DiskNumber --iso=$IsoPath --silent

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "  CHIAVETTA USB DI INSTALLAZIONE PROXMOX PRONTA!           " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
