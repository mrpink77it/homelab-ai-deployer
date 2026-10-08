using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
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
            Logger.Log("Esecuzione come Amministratore: " + isAdmin);

            if (!isAdmin)
            {
                MessageBox.Show("Questa applicazione richiede privilegi di Amministratore per la scrittura RAW dei dischi.", "Privilegi Insufficienti", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }

            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            {
                Logger.Log("CRASH NON GESTITO: " + e.ExceptionObject);
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
                string logLine = "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "] " + message + Environment.NewLine;
                File.AppendAllText(LogFilePath, logLine, Encoding.UTF8);
            }
            catch
            {
                // Ignora eccezioni di log
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
            this.Text = "Proxmox AI Deployer - USB ISO Customizer v5.0";
            this.Size = new System.Drawing.Size(540, 430);
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.StartPosition = FormStartPosition.CenterScreen;

            var lblUsb = new Label() { Text = "1. Seleziona Chiavetta USB Target:", Left = 20, Top = 20, Width = 480 };
            comboUsb = new ComboBox() { Left = 20, Top = 45, Width = 480, DropDownStyle = ComboBoxStyle.DropDownList };

            var groupNet = new GroupBox() { Text = "2. Configurazione Rete Server Proxmox", Left = 20, Top = 85, Width = 480, Height = 140 };
            radioDhcp = new RadioButton() { Text = "DHCP (Assegnazione Automatica)", Left = 20, Top = 25, Width = 420, Checked = true };
            radioStatic = new RadioButton() { Text = "IP Statico Manuale", Left = 20, Top = 50, Width = 420 };

            var lblIp = new Label() { Text = "IP/CIDR:", Left = 40, Top = 80, Width = 60 };
            txtIp = new TextBox() { Left = 100, Top = 77, Width = 140, Text = "192.168.1.150/24", Enabled = false };

            var lblGw = new Label() { Text = "Gateway:", Left = 250, Top = 80, Width = 60 };
            txtGateway = new TextBox() { Left = 310, Top = 77, Width = 140, Text = "192.168.1.1", Enabled = false };

            radioDhcp.CheckedChanged += (s, e) => { txtIp.Enabled = !radioDhcp.Checked; txtGateway.Enabled = !radioDhcp.Checked; };
            radioStatic.CheckedChanged += (s, e) => { txtIp.Enabled = radioStatic.Checked; txtGateway.Enabled = radioStatic.Checked; };

            groupNet.Controls.Add(radioDhcp);
            groupNet.Controls.Add(radioStatic);
            groupNet.Controls.Add(lblIp);
            groupNet.Controls.Add(txtIp);
            groupNet.Controls.Add(lblGw);
            groupNet.Controls.Add(txtGateway);

            btnCreate = new Button() { Text = "CREA ISO CUSTOM E SCRIVI SU USB", Left = 20, Top = 240, Width = 480, Height = 45, FlatStyle = FlatStyle.System };
            btnCreate.Click += async (s, e) => await StartProcessAsync();

            progressBar = new ProgressBar() { Left = 20, Top = 300, Width = 480, Height = 20 };
            lblStatus = new Label() { Text = "Stato: Seleziona unita USB e avvia il processo.", Left = 20, Top = 330, Width = 480 };

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
                string wmiQuery = "SELECT * FROM Win32_DiskDrive WHERE InterfaceType='USB'";
                var searcher = new ManagementObjectSearcher(wmiQuery);
                foreach (ManagementObject drive in searcher.Get())
                {
                    string model = drive["Model"] != null ? drive["Model"].ToString()! : "USB Drive";
                    string deviceId = drive["DeviceID"] != null ? drive["DeviceID"].ToString()! : "";
                    ulong sizeBytes = Convert.ToUInt64(drive["Size"]);
                    double sizeGb = Math.Round((double)sizeBytes / (1024 * 1024 * 1024), 1);

                    var usbItem = new UsbDriveItem() { DisplayName = model + " (" + sizeGb + " GB)", DeviceID = deviceId };
                    comboUsb.Items.Add(usbItem);
                    Logger.Log("Trovata USB: " + usbItem.DisplayName + " [" + deviceId + "]");
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
                Logger.Log("ERRORE lettura USB: " + ex.Message);
                MessageBox.Show("Errore lettura USB: " + ex.Message, "Errore", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private async Task StartProcessAsync()
        {
            if (!(comboUsb.SelectedItem is UsbDriveItem targetUsb))
            {
                MessageBox.Show("Seleziona una chiavetta USB valida!", "Attenzione", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string msgConfirm = "ATTENZIONE: TUTTI I DATI sulla chiavetta:\n\n" +
                                targetUsb.DisplayName + "\n\n" +
                                "VERRANNO CANCELLATI PER CREARE LA CHIAVETTA BOOTABLE AUTOMATICA!\n\n" +
                                "Vuoi continuare?";

            var confirm = MessageBox.Show(msgConfirm, "Conferma Formattazione USB", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (confirm != DialogResult.Yes) return;

            btnCreate.Enabled = false;
            comboUsb.Enabled = false;

            try
            {
                Logger.Log("Inizio processo di personalizzazione ISO e Scrittura RAW su: " + targetUsb.DisplayName + " (" + targetUsb.DeviceID + ")");

                string tempDir = Path.Combine(Path.GetTempPath(), "proxmox-builder");
                string extractedIsoDir = Path.Combine(tempDir, "extracted-iso");
                Directory.CreateDirectory(tempDir);
                if (Directory.Exists(extractedIsoDir))
                {
                    Directory.Delete(extractedIsoDir, true);
                }
                Directory.CreateDirectory(extractedIsoDir);

                string originalIsoPath = Path.Combine(tempDir, "proxmox-ve-latest.iso");
                string customIsoPath = Path.Combine(tempDir, "proxmox-ve-custom.iso");

                // Step 1: Download ISO Proxmox
                lblStatus.Text = "Stato: Verifica e Download ISO Proxmox VE...";
                progressBar.Value = 10;
                await DownloadIsoAsync("https://enterprise.proxmox.com/iso/proxmox-ve_8.2-1.iso", originalIsoPath);

                // Step 2: Estrazione ISO in cartella temporanea
                lblStatus.Text = "Stato: Estrazione contenuto ISO Proxmox in corso...";
                progressBar.Value = 20;
                await ExtractIsoAsync(originalIsoPath, extractedIsoDir);

                // Step 3: Iniezione file di personalizzazione nella root dell'ISO estratta
                lblStatus.Text = "Stato: Iniezione answer.toml, prerun.sh e postrun.sh nell ISO...";
                progressBar.Value = 40;

                string prerunPath = Path.Combine(extractedIsoDir, "prerun.sh");
                await DownloadFileAsync("https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/iso-builder/pre-install-check.sh", prerunPath);

                string answerPath = Path.Combine(extractedIsoDir, "answer.toml");
                File.WriteAllText(answerPath, BuildAnswerToml(), Encoding.UTF8);

                string postrunPath = Path.Combine(extractedIsoDir, "postrun.sh");
                File.WriteAllText(postrunPath, BuildPostInstallScript(), new UTF8Encoding(false));

                // Step 4: Ricostruzione ISO Ibrida Bootabile
                lblStatus.Text = "Stato: Ricreazione immagine ISO bootabile custom...";
                progressBar.Value = 55;
                await BuildCustomIsoAsync(extractedIsoDir, customIsoPath);

                // Step 5: Scrittura RAW Diretta (dd style) della ISO Modificata sulla USB
                lblStatus.Text = "Stato: Scrittura RAW della ISO Custom su USB...";
                progressBar.Value = 70;
                await FlashIsoToUsbRawAsync(targetUsb.DeviceID, customIsoPath);

                progressBar.Value = 100;
                lblStatus.Text = "Stato: CREAZIONE E SCRITTURA COMPLETATE CON SUCCESSO!";
                Logger.Log("=== CREAZIONE E SCRITTURA COMPLETATE CON SUCCESSO ===");
                MessageBox.Show("Chiavetta USB Proxmox Custom creata con successo!", "Completato", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                Logger.Log("ERRORE FATALE: " + ex.Message + "\nStackTrace: " + ex.StackTrace);
                MessageBox.Show("Errore durante la creazione: " + ex.Message + "\n\nConsulta 'app.log' per maggiori dettagli.", "Errore Fatale", MessageBoxButtons.OK, MessageBoxIcon.Error);
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
            sb.AppendLine("source = \"" + netSource + "\"");
            sb.AppendLine("cidr = \"" + cidr + "\"");
            sb.AppendLine("gateway = \"" + gateway + "\"");
            sb.AppendLine("dns = \"1.1.1.1\"");
            sb.AppendLine("dns2 = \"8.8.8.8\"");
            sb.AppendLine();
            sb.AppendLine("[disk_setup]");
            sb.AppendLine("filesystem = \"zfs (RAID0)\"");
            sb.AppendLine("disk_list = [\"filter:first_matched\"]");
            sb.AppendLine();
            sb.AppendLine("[prerun]");
            sb.AppendLine("source = \"from-iso\"");
            sb.AppendLine();
            sb.AppendLine("[postrun]");
            sb.AppendLine("source = \"from-iso\"");

            return sb.ToString();
        }

        private string BuildPostInstallScript()
        {
            return @"#!/bin/bash
set -e
exec > /var/log/homelab-firstboot.log 2>&1
echo '=== INIZIO SETUP FIRST-BOOT PROXMOX + KDE ==='

echo '1. Creazione utente homelab con privilegi sudo senza password...'
if ! id -u homelab >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo homelab
    echo 'homelab:proxmox' | chpasswd
    echo 'homelab ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/homelab
    chmod 0440 /etc/sudoers.d/homelab
fi

echo '2. Installazione KDE Plasma e SDDM...'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y kde-plasma-desktop sddm xorg curl git build-essential

echo '3. Configurazione Autologin SDDM...'
mkdir -p /etc/sddm.conf.d
cat << 'EOF' > /etc/sddm.conf.d/autologin.conf
[Autologin]
User=homelab
Session=plasma
EOF

echo '4. Configurazione Autostart KDE...'
mkdir -p /home/homelab/.config/autostart
mkdir -p /home/homelab/scripts

cat << 'EOF' > /home/homelab/scripts/post-kde-deploy.sh
#!/bin/bash
echo 'Avvio procedura di configurazione guidata Homelab AI...'
if [ -f /usr/bin/konsole ]; then
    konsole -e bash -c 'echo ""=== HOMELAB AI DEPLOYER ===""; sleep 2; sudo rm -rf /opt/homelab-ai-deployer && sudo git clone https://github.com/mrpink77it/homelab-ai-deployer.git /opt/homelab-ai-deployer && cd /opt/homelab-ai-deployer && sudo chmod +x install.sh && sudo ./install.sh; exec bash'
fi
EOF

chmod +x /home/homelab/scripts/post-kde-deploy.sh
chown -R homelab:homelab /home/homelab/

cat << 'EOF' > /home/homelab/.config/autostart/homelab-ai.desktop
[Desktop Entry]
Type=Application
Name=Homelab AI Deployer
Exec=/home/homelab/scripts/post-kde-deploy.sh
X-GNOME-Autostart-enabled=true
EOF

chown -R homelab:homelab /home/homelab/.config
systemctl set-default graphical.target
echo '=== SETUP COMPLETATO CON SUCCESSO ==='
";
        }

        private async Task DownloadIsoAsync(string url, string destination)
        {
            if (File.Exists(destination))
            {
                long length = new FileInfo(destination).Length;
                if (length > 500 * 1024 * 1024)
                {
                    Logger.Log("File ISO gia presente e valido (" + length + " byte).");
                    return;
                }
                File.Delete(destination);
            }
            await DownloadFileAsync(url, destination);
        }

        private async Task DownloadFileAsync(string url, string destination)
        {
            var handler = new HttpClientHandler() { AllowAutoRedirect = true };
            using var client = new HttpClient(handler);
            client.Timeout = TimeSpan.FromMinutes(20);
            client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64)");

            using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            response.EnsureSuccessStatusCode();

            using var streamToRead = await response.Content.ReadAsStreamAsync();
            using var streamToWrite = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, 8192, true);
            await streamToRead.CopyToAsync(streamToWrite);
        }

        private async Task ExtractIsoAsync(string isoPath, string outputDir)
        {
            Logger.Log("Mount ed estrazione ISO tramite PowerShell/7-Zip...");
            string psCmd = \$@"
$iso = '{isoPath}';$out = '{outputDir}';
Mount-DiskImage -ImagePath \$iso;
$vol = (Get-DiskImage -ImagePath$iso | Get-Volume).DriveLetter;
Copy-Item -Path ""\$($vol):\*"" -Destination $out -Recurse -Force;
Dismount-DiskImage -ImagePath \$iso;
";
            
            await RunPowerShellAsync(psCmd);
        }

        private async Task BuildCustomIsoAsync(string sourceDir, string outputIsoPath)
        {
            Logger.Log("Ricostruzione ISO bootabile...");
            string psCmd = \$@"
$src = '{sourceDir}';$out = '{outputIsoPath}';
if (Get-Command oscimagetool -ErrorAction SilentlyContinue) {{
    oscimagetool -n -m -b""\$src/boot/grub/efi.img"" ""$src"" ""$out""
}} else {{
    Write-Output 'oscimagetool non trovato, utilizzo fallback PowerShell';
    New-Item -Path \$out -ItemType File -Force
}}
";

            await RunPowerShellAsync(psCmd);

            if (!File.Exists(outputIsoPath) || new FileInfo(outputIsoPath).Length == 0)
            {
                throw new Exception("Impossibile generare la nuova ISO custom. Verificare i requisiti di sistema per la creazione di ISO bootabili.");
            }
        }

        private async Task FlashIsoToUsbRawAsync(string deviceId, string isoPath)
        {
            string diskNum = Regex.Match(deviceId, @"\d+").Value;
            if (string.IsNullOrEmpty(diskNum))
            {
                throw new Exception("Impossibile estrarre il numero di disco da DeviceID: " + deviceId);
            }

            string physicalDrive = @"\\.\PhysicalDrive" + diskNum;
            Logger.Log("Inizio Scrittura RAW Diretta (dd style) su: " + physicalDrive +
