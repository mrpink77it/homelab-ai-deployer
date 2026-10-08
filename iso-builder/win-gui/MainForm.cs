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
            this.Text = "Proxmox AI Deployer - USB Creator v4.9 (Direct RAW Write)";
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
            lblStatus = new Label { Text = "Stato: Seleziona unita USB e avvia il processo.", Left = 20, Top = 330, Width = 480 };

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

                    var usbItem = new UsbDriveItem { DisplayName = model + " (" + sizeGb + " GB)", DeviceID = deviceId };
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
            if (comboUsb.SelectedItem is not UsbDriveItem targetUsb)
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
                Logger.Log("Inizio processo RAW (dd-style) per l unita: " + targetUsb.DisplayName + " (" + targetUsb.DeviceID + ")");

                string tempDir = Path.Combine(Path.GetTempPath(), "proxmox-builder");
