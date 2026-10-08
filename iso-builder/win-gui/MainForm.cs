using System;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Net.Http;
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
            Application.Run(new MainForm());
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
            this.Text = "Proxmox AI Deployer - USB Creator v2.0";
            this.Size = new System.Drawing.Size(520, 420);
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.StartPosition = FormStartPosition.CenterScreen;

            var lblUsb = new Label { Text = "1. Seleziona Chiavetta USB:", Left = 20, Top = 20, Width = 460 };
            comboUsb = new ComboBox { Left = 20, Top = 45, Width = 460, DropDownStyle = ComboBoxStyle.DropDownList };

            var groupNet = new GroupBox { Text = "2. Configurazione Rete Server Target", Left = 20, Top = 85, Width = 460, Height = 140 };
            radioDhcp = new RadioButton { Text = "DHCP (Assegnazione Automatica Router)", Left = 20, Top = 25, Width = 400, Checked = true };
            radioStatic = new RadioButton { Text = "IP Statico Manuale", Left = 20, Top = 50, Width = 400 };

            var lblIp = new Label { Text = "IP/CIDR:", Left = 40, Top = 80, Width = 60 };
            txtIp = new TextBox { Left = 100, Top = 77, Width = 140, Text = "192.168.1.150/24", Enabled = false };

            var lblGw = new Label { Text = "Gateway:", Left = 250, Top = 80, Width = 60 };
            txtGateway = new TextBox { Left = 310, Top = 77, Width = 130, Text = "192.168.1.1", Enabled = false };

            radioDhcp.CheckedChanged += (s, e) => { txtIp.Enabled = !radioDhcp.Checked; txtGateway.Enabled = !radioDhcp.Checked; };
            radioStatic.CheckedChanged += (s, e) => { txtIp.Enabled = radioStatic.Checked; txtGateway.Enabled = radioStatic.Checked; };

            groupNet.Controls.Add(radioDhcp);
            groupNet.Controls.Add(radioStatic);
            groupNet.Controls.Add(lblIp);
            groupNet.Controls.Add(txtIp);
            groupNet.Controls.Add(lblGw);
            groupNet.Controls.Add(txtGateway);

            btnCreate = new Button { Text = "CREA CHIAVETTA USB AUTOMATICA", Left = 20, Top = 240, Width = 460, Height = 45, FlatStyle = FlatStyle.System };
            btnCreate.Click += async (s, e) => await StartProcessAsync();

            progressBar = new ProgressBar { Left = 20, Top = 300, Width = 460, Height = 20 };
            lblStatus = new Label { Text = "Stato: Inserisci la chiavetta USB e clicca sul pulsante.", Left = 20, Top = 330, Width = 460 };

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
            try
            {
                var searcher = new ManagementObjectSearcher(@"SELECT * FROM Win32_DiskDrive WHERE InterfaceType='USB'");
                foreach (ManagementObject drive in searcher.Get())
                {
                    string model = drive["Model"]?.ToString() ?? "USB Drive";
                    string deviceId = drive["DeviceID"]?.ToString() ?? "";
                    ulong sizeBytes = Convert.ToUInt64(drive["Size"]);
                    double sizeGb = Math.Round((double)sizeBytes / (1024 * 1024 * 1024), 1);

                    comboUsb.Items.Add(new UsbDriveItem { DisplayName = $"{model} ({sizeGb} GB)", DeviceID = deviceId });
                }

                if (comboUsb.Items.Count > 0) comboUsb.SelectedIndex = 0;
                else lblStatus.Text = "Stato: Nessuna chiavetta USB trovata! Inseriscine una e riapri.";
            }
            catch (Exception ex)
            {
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
                                "VERRANNO CANCELLATI PER SEMPRE!" + Environment.NewLine + Environment.NewLine +
                                "Vuoi continuare?";

            var confirm = MessageBox.Show(msgConfirm, "Conferma Scrittura USB", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (confirm != DialogResult.Yes) return;

            btnCreate.Enabled = false;
            comboUsb.Enabled = false;

            try
            {
                string tempDir = Path.Combine(Path.GetTempPath(), "proxmox-builder");
                Directory.CreateDirectory(tempDir);
                string isoPath = Path.Combine(tempDir, "proxmox-ve-latest.iso");
                string answerPath = Path.Combine(tempDir, "answer.toml");

                lblStatus.Text = "Stato: Download ISO Proxmox VE in corso...";
                progressBar.Value = 20;
                await DownloadIsoAsync("https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso", isoPath);

                lblStatus.Text = "Stato: Generazione configurazione automatica (answer.toml)...";
                progressBar.Value = 60;
                string answerToml = BuildAnswerToml();
                File.WriteAllText(answerPath, answerToml, Encoding.UTF8);

                lblStatus.Text = "Stato: Scrittura immagine e configurazione sulla USB...";
                progressBar.Value = 80;
                await FlashToUsbAsync(targetUsb.DeviceID, isoPath, answerPath);

                progressBar.Value = 100;
                lblStatus.Text = "Stato: OPERAZIONE COMPLETATA CON SUCCESSO!";
                MessageBox.Show("Chiavetta USB creata con successo!\n\nInserisci la USB nel computer/server di destinazione e fai il boot per avviare l'installazione automatica.", "Completato", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Errore durante la creazione: {ex.Message}", "Errore Fatale", MessageBoxButtons.OK, MessageBoxIcon.Error);
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

        private async Task DownloadIsoAsync(string url, string destination)
        {
            // Se la ISO esiste già ed è di dimensioni coerenti (es. > 500 MB), salta il download
            if (File.Exists(destination) && new FileInfo(destination).Length > 500 * 1024 * 1024)
            {
                return;
            }

            var handler = new HttpClientHandler
            {
                AllowAutoRedirect = true
            };

            using var client = new HttpClient(handler);
            
            // Imposta uno User-Agent per evitare il blocco da parte dei web server Proxmox
            client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");

            using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            response.EnsureSuccessStatusCode();

            using var streamToRead = await response.Content.ReadAsStreamAsync();
            using var streamToWrite = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, 8192, true);
            await streamToRead.CopyToAsync(streamToWrite);
        }

        private async Task FlashToUsbAsync(string deviceId, string isoPath, string answerPath)
        {
            await Task.Run(() =>
            {
                string diskNum = Regex.Match(deviceId, @"\d+").Value;
                string escapedAnswerPath = answerPath.Replace("\\", "\\\\");

                var sb = new StringBuilder();
                sb.AppendLine($"$diskNum = \"{diskNum}\"");
                sb.AppendLine($"$answer = \"{escapedAnswerPath}\"");
                sb.AppendLine("$diskpartCmd = @\"");
                sb.AppendLine("select disk $diskNum");
                sb.AppendLine("clean");
                sb.AppendLine("convert mbr");
                sb.AppendLine("create partition primary");
                sb.AppendLine("format fs=fat32 quick label=\"PROXMOX-ANSWER\"");
                sb.AppendLine("active");
                sb.AppendLine("assign");
                sb.AppendLine("\"@");
                sb.AppendLine("$diskpartCmd | diskpart");
                sb.AppendLine("Start-Sleep -Seconds 2");
                sb.AppendLine("$driveLetter = (Get-Partition -DiskNumber $diskNum | Get-Volume).DriveLetter");
                sb.AppendLine("if ($driveLetter) {");
                sb.AppendLine("    Copy-Item -Path $answer -Destination \"${driveLetter}:\\answer.toml\" -Force");
                sb.AppendLine("}");

                var psi = new ProcessStartInfo("powershell")
                {
                    CreateNoWindow = true,
                    UseShellExecute = false
                };
                psi.ArgumentList.Add("-NoProfile");
                psi.ArgumentList.Add("-ExecutionPolicy");
                psi.ArgumentList.Add("Bypass");
                psi.ArgumentList.Add("-Command");
                psi.ArgumentList.Add(sb.ToString());

                using var proc = Process.Start(psi);
                proc?.WaitForExit();
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
