using System;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Net.Http;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace HomelabUSBBuilder
{
    internal static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            Logger.Log("=== AVVIO APPLICAZIONE ===");

            bool isAdmin = IsAdministrator();
            Logger.Log($"Esecuzione come Amministratore: {isAdmin}");

            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            {
                Logger.Log($"CRASH NON GESTITO: {e.ExceptionObject}");
            };

            Application.Run(new MainForm());
        }

        public static bool IsAdministrator()
        {
            using var identity = WindowsIdentity.GetCurrent();
            var principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
    }

    public static class Logger
    {
        private static readonly string LogFilePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "app.log");

        public static void Log(string message)
        {
            try
            {
                string logLine = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}{Environment.NewLine}";
                File.AppendAllText(LogFilePath, logLine, Encoding.UTF8);
            }
            catch
            {
                // Ignora eventuali eccezioni di log
            }
        }
    }

    public partial class MainForm : Form
    {
        private ComboBox comboUsb = null!;
        private RadioButton radioDhcp = null!;
        private RadioButton radioStatic = null!;
        private TextBox txtIp = null!;
        private TextBox txtGateway = null!;
        private Button btnCreate = null!;
        private ProgressBar progressBar = null!;
        private Label lblStatus = null!;

        public MainForm()
        {
            InitializeComponentLayout();
            LoadUsbDrives();
        }

        private void InitializeComponentLayout()
        {
            this.Text = "Proxmox AI Deployer - USB Creator v3.0 (KDE Auto-Install)";
            this.Size = new System.Drawing.Size(540, 430);
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.StartPosition = FormStartPosition.CenterScreen;

            var lblUsb = new Label { Text = "1. Seleziona Chiavetta USB Target:", Left = 20, Top = 20, Width = 480 };
            comboUsb = new ComboBox { Left = 20, Top = 45, Width = 480, DropDownStyle = ComboBoxStyle.DropDownList };

            var groupNet = new GroupBox { Text = "2. Configurazione Rete Server Proxmox", Left = 20, Top = 85, Width = 480, Height = 140 };
            radioDhcp = new RadioButton { Text = "DHCP (Assegnazione Automatica)", Left = 20, Top = 25, Width = 420, Checked = true };
            radioStatic = new RadioButton { Text = "IP Statico Manuale", Left = 20, Top = 50, Width = 420 };

            var lblIp = new Label { Text = "IP/CIDR:", Left = 40, Top = 80, Width = 60 };
            txtIp = new TextBox { Left = 100, Top = 77, Width = 140, Text = "192.168.1.150/24", Enabled = false };

            var lblGw = new Label { Text = "Gateway:", Left = 250, Top = 80, Width = 60 };
            txtGateway = new TextBox { Left = 310, Top = 77, Width = 140, Text = "192.168.1.1", Enabled = false };

            radioDhcp.CheckedChanged += (s, e) => { txtIp.Enabled = !radioDhcp.Checked; txtGateway.Enabled = !radioDhcp.Checked; };
            radioStatic.CheckedChanged += (s, e) => { txtIp.Enabled = radioStatic.Checked; txtGateway.Enabled = radioStatic.Checked; };

            groupNet.Controls.Add(radioDhcp);
            groupNet.Controls.Add(radioStatic);
            groupNet.Controls.Add(lblIp);
            groupNet.Controls.Add(txtIp);
            groupNet.Controls.Add(lblGw);
            groupNet.Controls.Add(txtGateway);

            btnCreate = new Button { Text = "CREA CHIAVETTA AUTOMATICA PROXMOX + KDE", Left = 20, Top = 240, Width = 480, Height = 45, FlatStyle = FlatStyle.System };
            btnCreate.Click += async (s, e) => await StartProcessAsync();

            progressBar = new ProgressBar { Left = 20, Top = 300, Width = 480, Height = 20 };
            lblStatus = new Label { Text = "Stato: Seleziona l'unità USB e avvia il processo.", Left = 20, Top = 330, Width = 480 };

            this.Controls.Add(lblUsb);
            this.Controls.Add(comboUsb);
            this.Controls.Add(groupNet);
            this.Controls.Add(btnCreate);
            this.Controls.Add(progressBar);
            this.Controls.Add(lblStatus);
        }

        private void LoadUsbDrives()
        {
            comboUsb.Items.Clear();
            Logger.Log("Ricerca chiavette USB collegate...");
            try
            {
                var searcher = new ManagementObjectSearcher(@"SELECT * FROM Win32_DiskDrive WHERE InterfaceType='USB'");
                foreach (ManagementObject drive in searcher.Get())
                {
                    string model = drive["Model"]?.ToString() ?? "USB Drive";
                    string deviceId = drive["DeviceID"]?.ToString() ?? "";
                    ulong sizeBytes = Convert.ToUInt64(drive["Size"]);
                    double sizeGb = Math.Round((double)sizeBytes / (1024 * 1024 * 1024), 1);

                    var usbItem = new UsbDriveItem { DisplayName = $"{model} ({sizeGb} GB)", DeviceID = deviceId };
                    comboUsb.Items.Add(usbItem);
                    Logger.Log($"Trovata USB: {usbItem.DisplayName} [{deviceId}]");
                }

                if (comboUsb.Items.Count > 0)
                {
                    comboUsb.SelectedIndex = 0;
                }
                else
                {
                    lblStatus.Text = "Stato: Nessuna chiavetta USB trovata!";
                    Logger.Log("Nessun dispositivo USB rilevato.");
                }
            }
            catch (Exception ex)
            {
                Logger.Log($"ERRORE lettura USB: {ex}");
                MessageBox.Show($"Errore lettura USB: {ex.Message}", "Errore", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private async Task StartProcessAsync()
        {
            if (comboUsb.SelectedItem is not UsbDriveItem targetUsb)
            {
                MessageBox.Show("Seleziona una chiavetta USB valida!", "Attenzione", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string msgConfirm = "ATTENZIONE: TUTTI I DATI sulla chiavetta:" + Environment.NewLine + Environment.NewLine +
                                targetUsb.DisplayName + Environment.NewLine + Environment.NewLine +
                                "VERRANNO CANCELLATI PER CREARE LA CHIAVETTA BOOTABLE AUTOMATICA!" + Environment.NewLine + Environment.NewLine +
                                "Vuoi continuare?";

            var confirm = MessageBox.Show(msgConfirm, "Conferma Formattazione USB", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (confirm != DialogResult.Yes) return;

            btnCreate.Enabled = false;
            comboUsb.Enabled = false;

            try
            {
                Logger.Log($"Inizio processo per l'unità: {targetUsb.DisplayName} ({targetUsb.DeviceID})");

                string tempDir = Path.Combine(Path.GetTempPath(), "proxmox-builder");
                Directory.CreateDirectory(tempDir);

                string isoPath = Path.Combine(tempDir, "proxmox-ve-latest.iso");
                string answerPath = Path.Combine(tempDir, "answer.toml");
                string preCheckPath = Path.Combine(tempDir, "pre-install-check.sh");
                string postInstallPath = Path.Combine(tempDir, "post-install.sh");

                // Step 1: Download ISO Proxmox
                lblStatus.Text = "Stato: Verifica e Download ISO Proxmox VE...";
                progressBar.Value = 10;
                await DownloadIsoAsync("https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso", isoPath);

                // Step 2: Download pre-install-check.sh da GitHub
                lblStatus.Text = "Stato: Download script pre-install-check.sh...";
                progressBar.Value = 15;
                await DownloadFileAsync("https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/iso-builder/pre-install-check.sh", preCheckPath);

                // Step 3: Generazione answer.toml
                lblStatus.Text = "Stato: Generazione answer.toml...";
                progressBar.Value = 20;
                File.WriteAllText(answerPath, BuildAnswerToml(), Encoding.UTF8);

                // Step 4: Generazione post-install.sh
                lblStatus.Text = "Stato: Generazione script di installazione KDE e Autologin...";
                progressBar.Value = 25;
                File.WriteAllText(postInstallPath, BuildPostInstallScript(), new UTF8Encoding(false));

                // Step 5: Formattazione USB, estrazione ISO, patch GRUB e copia script
                await FlashToUsbAsync(targetUsb.DeviceID, answerPath, isoPath, preCheckPath, postInstallPath);

                progressBar.Value = 100;
                lblStatus.Text = "Stato: CREAZIONE E VERIFICA COMPLETATE CON SUCCESSO!";
                Logger.Log("=== CREAZIONE E VERIFICA COMPLETATE CON SUCCESSO ===");
                MessageBox.Show("Chiavetta USB Proxmox + KDE autologin creata con successo!", "Completato", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                Logger.Log($"ERRORE FATALE: {ex}");
                MessageBox.Show($"Errore durante la creazione: {ex.Message}\n\nConsulta 'app.log' per maggiori dettagli.", "Errore Fatale", MessageBoxButtons.OK, MessageBoxIcon.Error);
                lblStatus.Text = "Stato: Errore riscontrato.";
            }
            finally
            {
                btnCreate.Enabled = true;
                comboUsb.Enabled = true;
            }
        }

        private string BuildAnswerToml()
        {
            string netSource = radioDhcp.Checked ? "from-dhcp" : "from-answer";
            string cidr = radioDhcp.Checked ? "dhcp" : txtIp.Text;
            string gateway = radioDhcp.Checked ? "" : txtGateway.Text;

            var sb = new StringBuilder();
            sb.AppendLine("[global]");
            sb.AppendLine("keyboard = \"it\"");
            sb.AppendLine("country = \"it\"");
            sb.AppendLine("timezone = \"Europe/Rome\"");
            sb.AppendLine("fqdn = \"pve.homelab.local\"");
            sb.AppendLine("mailto = \"admin@homelab.local\"");
            sb.AppendLine("root_password = \"proxmox\"");
            sb.AppendLine("reboot_mode = \"reboot\"");
            sb.AppendLine();
            sb.AppendLine("[network]");
            sb.AppendLine($"source = \"{netSource}\"");
            sb.AppendLine($"cidr = \"{cidr}\"");
            sb.AppendLine($"gateway = \"{gateway}\"");
            sb.AppendLine("dns = \"1.1.1.1\"");
            sb.AppendLine("dns2 = \"8.8.8.8\"");
            sb.AppendLine();
            sb.AppendLine("[disk_setup]");
            sb.AppendLine("filesystem = \"zfs (RAID0)\"");
            sb.AppendLine("disk_list = [\"filter:first_matched\"]");

            return sb.ToString();
        }

        private string BuildPostInstallScript()
        {
            var sb = new StringBuilder();
            sb.AppendLine("#!/bin/bash");
            sb.AppendLine("set -e");
            sb.AppendLine("exec > /var/log/homelab-firstboot.log 2>&1");
            sb.AppendLine("echo '=== INIZIO SETUP FIRST-BOOT PROXMOX + KDE ==='");

            sb.AppendLine("echo '1. Creazione utente homelab...'");
            sb.AppendLine("if ! id -u homelab >/dev/null 2>&1; then");
            sb.AppendLine("    useradd -m -s /bin/bash -G sudo homelab");
            sb.AppendLine("    echo 'homelab:proxmox' | chpasswd");
            sb.AppendLine("fi");

            sb.AppendLine("echo '2. Installazione KDE Plasma e SDDM...'");
            sb.AppendLine("export DEBIAN_FRONTEND=noninteractive");
            sb.AppendLine("apt-get update");
            sb.AppendLine("apt-get install -y kde-plasma-desktop sddm xorg curl git build-essential");

            sb.AppendLine("echo '3. Configurazione Autologin SDDM...'");
            sb.AppendLine("mkdir -p /etc/sddm.conf.d");
            sb.AppendLine("cat << 'EOF' > /etc/sddm.conf.d/autologin.conf");
            sb.AppendLine("[Autologin]");
            sb.AppendLine("User=homelab");
            sb.AppendLine("Session=plasma");
            sb.AppendLine("EOF");

            sb.AppendLine("echo '4. Configurazione Autostart KDE...'");
            sb.AppendLine("mkdir -p /home/homelab/.config/autostart");
            sb.AppendLine("mkdir -p /home/homelab/scripts");

            sb.AppendLine("cat << 'EOF' > /home/homelab/scripts/post-kde-deploy.sh");
            sb.AppendLine("#!/bin/bash");
            sb.AppendLine("echo 'Avvio procedura di configurazione guidata Homelab AI...'");
            sb.AppendLine("if [ -f /usr/bin/konsole ]; then");
            sb.AppendLine("    konsole -e bash -c 'echo \"=== HOMELAB AI DEPLOYER ===\"; sleep 2; git clone https://github.com/mrpink77it/homelab-ai-deployer.git /tmp/deployer && cd /tmp/deployer && ./deploy.sh; exec bash'");
            sb.AppendLine("fi");
            sb.AppendLine("EOF");

            sb.AppendLine("chmod +x /home/homelab/scripts/post-kde-deploy.sh");
            sb.AppendLine("chown -R homelab:homelab /home/homelab/");

            sb.AppendLine("cat << 'EOF' > /home/homelab/.config/autostart/homelab-ai.desktop");
            sb.AppendLine("[Desktop Entry]");
            sb.AppendLine("Type=Application");
            sb.AppendLine("Name=Homelab AI Deployer");
            sb.AppendLine("Exec=/home/homelab/scripts/post-kde-deploy.sh");
            sb.AppendLine("X-GNOME-Autostart-enabled=true");
            sb.AppendLine("EOF");

            sb.AppendLine("chown -R homelab:homelab /home/homelab/.config");
            sb.AppendLine("systemctl set-default graphical.target");
            sb.AppendLine("echo '=== SETUP COMPLETATO CON SUCCESSO ==='");
            return sb.ToString();
        }

        private async Task DownloadIsoAsync(string url, string destination)
        {
            if (File.Exists(destination))
            {
                long length = new FileInfo(destination).Length;
                if (length > 500 * 1024 * 1024)
                {
                    Logger.Log($"File ISO già presente e valido ({length} byte).");
                    return;
                }
                File.Delete(destination);
            }
            await DownloadFileAsync(url, destination);
        }

        private async Task DownloadFileAsync(string url, string destination)
        {
            var handler = new HttpClientHandler { AllowAutoRedirect = true };
            using var client = new HttpClient(handler);
            client.Timeout = TimeSpan.FromMinutes(20);
            client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64)");

            using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            response.EnsureSuccessStatusCode();

            using var streamToRead = await response.Content.ReadAsStreamAsync();
            using var streamToWrite = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, 8192, true);
            await streamToRead.CopyToAsync(streamToWrite);
        }

        private async Task FlashToUsbAsync(string deviceId, string answerPath, string isoPath, string preCheckPath, string postInstallPath)
        {
            await Task.Run(() =>
            {
                string diskNum = Regex.Match(deviceId, @"\d+").Value;
                if (string.IsNullOrEmpty(diskNum))
                {
                    throw new Exception($"Impossibile estrarre il numero di disco da DeviceID: {deviceId}");
                }

                string escAnswer = answerPath.Replace("\\", "\\\\");
                string escIso = isoPath.Replace("\\", "\\\\");
                string escPre = preCheckPath.Replace("\\", "\\\\");
                string escPost = postInstallPath.Replace("\\", "\\\\");

                var sb = new StringBuilder();
                sb.AppendLine($"$diskNum = \"{diskNum}\"");
                sb.AppendLine($"$answer = \"{escAnswer}\"");
                sb.AppendLine($"$iso = \"{escIso}\"");
                sb.AppendLine($"$preCheck = \"{escPre}\"");
                sb.AppendLine($"$postInstall = \"{escPost}\"");

                // Step 1: Formattazione GPT/FAT32
                sb.AppendLine("Write-Host 'STATUS:30:Formattazione disco USB in GPT/FAT32...'");
                sb.AppendLine("$diskpartScript = @\"");
                sb.AppendLine("select disk $diskNum");
                sb.AppendLine("clean");
                sb.AppendLine("convert gpt");
                sb.AppendLine("create partition primary");
                sb.AppendLine("format fs=fat32 quick label=\"PROXMOXAID\"");
                sb.AppendLine("assign");
                sb.AppendLine("\"@");

                sb.AppendLine("$dpOutput = $diskpartScript | diskpart");
                sb.AppendLine("if ($dpOutput -match 'Errore del servizio Dischi virtuali' -or $dpOutput -match 'Error') { throw 'Errore durante formattazione con DiskPart.' }");

                sb.AppendLine("Start-Sleep -Seconds 3");

                // Step 2: Rilevamento lettera di unità
                sb.AppendLine("$vol = Get-Partition -DiskNumber $diskNum | Get-Volume");
                sb.AppendLine("if (-not ($vol -and $vol.DriveLetter)) { throw 'Impossibile identificare la lettera della USB.' }");
                sb.AppendLine("$driveLetter = $vol.DriveLetter.ToString().Trim()");

                // Step 3: Montaggio ISO e copia file
                sb.AppendLine("Write-Host 'STATUS:40:Montaggio ISO Proxmox ed estrazione dei file...'");
                sb.AppendLine("$isoMount = Mount-DiskImage -ImagePath $iso -PassThru");
                sb.AppendLine("$isoVol = $isoMount | Get-Volume");
                sb.AppendLine("$isoDrive = $isoVol.DriveLetter");

                sb.AppendLine("Write-Host 'STATUS:50:Copia dei file ISO sulla chiavetta USB...'");
                sb.AppendLine("Copy-Item -Path ($isoDrive + ':\\*') -Destination ($driveLetter + ':\\') -Recurse -Force -ErrorAction Stop");

                // Step 4: Copia file di configurazione e script nella radice USB
                sb.AppendLine("Write-Host 'STATUS:65:Iniezione answer.toml, pre-install e post-install script...'");
                sb.AppendLine("Copy-Item -Path $answer -Destination ($driveLetter + ':\\answer.toml') -Force");
                sb.AppendLine("Copy-Item -Path $preCheck -Destination ($driveLetter + ':\\pre-install-check.sh') -Force");
                sb.AppendLine("Copy-Item -Path $postInstall -Destination ($driveLetter + ':\\post-install.sh') -Force");

                // Step 5: Patch GRUB Bootloader
                sb.AppendLine("Write-Host 'STATUS:70:Modifica configurazione GRUB bootloader sulla USB...'");
                sb.AppendLine("$grubCfg = $driveLetter + ':\\boot\\grub\\grub.cfg'");
                sb.AppendLine("if (Test-Path $grubCfg) {");
                sb.AppendLine("    $fileObj = Get-Item -Path $grubCfg");
                sb.AppendLine("    if ($fileObj.IsReadOnly) { $fileObj.IsReadOnly = $false }");
                sb.AppendLine("    $content = Get-Content -Path $grubCfg -Raw -Encoding UTF8");
                sb.AppendLine("    $content = $content -replace 'linux /boot/linux26', 'linux /boot/linux26 proxmox-start-script=/game/pre-install-check.sh proxmox-post-hook=/game/post-install.sh'");
                sb.AppendLine("    Set-Content -Path $grubCfg -Value $content -Encoding UTF8 -Force -ErrorAction Stop");
                sb.AppendLine("}");

                // Step 6: VERIFICA INTEGRITÀ E COERENZA DEI FILE SCRITTI
                sb.AppendLine("Write-Host 'STATUS:75:Avvio verifica di coerenza dei dati scritti sulla USB...'");
                sb.AppendLine("$isoFiles = Get-ChildItem -Path ($isoDrive + ':\\') -Recurse -File");
                sb.AppendLine("$totalFiles = $isoFiles.Count");
                sb.AppendLine("$currentIndex = 0");
                sb.AppendLine("$corruptCount = 0");

                sb.AppendLine("foreach ($file in $isoFiles) {");
                sb.AppendLine("    $currentIndex++");
                sb.AppendLine("    $pct = 75 + [math]::Round(($currentIndex / $totalFiles) * 23)");
                sb.AppendLine("    $relativePath = $file.FullName.Substring(3)");
                sb.AppendLine("    Write-Host \"STATUS:${pct}:Verifica [$currentIndex/$totalFiles]: $relativePath\"");

                sb.AppendLine("    $targetPath = Join-Path ($driveLetter + ':\\') $relativePath");
                sb.AppendLine("    if (-not (Test-Path $targetPath)) {");
                sb.AppendLine("        Write-Host \"ERRORE VERIFICA: File non trovato sulla USB: $targetPath\"");
                sb.AppendLine("        $corruptCount++; break");
                sb.AppendLine("    }");

                sb.AppendLine("    $targetFile = Get-Item -Path $targetPath");

                // Controllo case-insensitive diretto sul nome file per escludere grub.cfg
                sb.AppendLine("    if ($file.Name -ine 'grub.cfg') {");
                sb.AppendLine("        if ($file.Length -ne $targetFile.Length) {");
                sb.AppendLine("            Write-Host \"ERRORE VERIFICA: Dimensione non corrispondente per $relativePath (ISO: $($file.Length), USB: $($targetFile.Length))\"");
                sb.AppendLine("            $corruptCount++; break");
                sb.AppendLine("        }");
                sb.AppendLine("    }");
                sb.AppendLine("}");

                // Smontaggio immagine ISO silenzioso
                sb.AppendLine("Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null");

                sb.AppendLine("if ($corruptCount -gt 0) { throw 'Verifica coerenza dati fallita.' }");
                sb.AppendLine("Write-Host 'STATUS:99:Verifica dati completata con successo.'");

                var psi = new ProcessStartInfo("powershell")
                {
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                psi.ArgumentList.Add("-NoProfile");
                psi.ArgumentList.Add("-ExecutionPolicy");
                psi.ArgumentList.Add("Bypass");
                psi.ArgumentList.Add("-Command");
                psi.ArgumentList.Add(sb.ToString());

                using var proc = new Process { StartInfo = psi };
                bool hasErrors = false;

                proc.OutputDataReceived += (s, e) =>
                {
                    if (string.IsNullOrWhiteSpace(e.Data)) return;
                    Logger.Log($"[PowerShell]: {e.Data}");

                    if (e.Data.StartsWith("STATUS:"))
                    {
                        var parts = e.Data.Split(new[] { ':' }, 3);
                        if (parts.Length >= 3 && int.TryParse(parts[1], out int pct))
                        {
                            string msg = parts[2];
                            this.Invoke(new Action(() =>
                            {
                                progressBar.Value = Math.Min(100, Math.Max(0, pct));
                                lblStatus.Text = $"Stato: {msg}";
                            }));
                        }
                    }
                    else if (e.Data.Contains("ERRORE") || e.Data.Contains("throw"))
                    {
                        hasErrors = true;
                    }
                };

                proc.ErrorDataReceived += (s, e) =>
                {
                    if (!string.IsNullOrWhiteSpace(e.Data))
                    {
                        Logger.Log($"[PowerShell Errore]: {e.Data}");
                        hasErrors = true;
                    }
                };

                proc.Start();
                proc.BeginOutputReadLine();
                proc.BeginErrorReadLine();
                proc.WaitForExit();

                if (proc.ExitCode != 0 || hasErrors)
                {
                    throw new Exception("La creazione o la verifica della chiavetta USB è fallita. Verifica app.log.");
                }
            });
        }
    }

    public class UsbDriveItem
    {
        public string DisplayName { get; set; } = "";
        public string DeviceID { get; set; } = "";
        public override string ToString() => DisplayName;
    }
}
