// TVBox 安装器
// - 自包含：内嵌 app.zip 资源（csc /resource:app.zip,app.zip）
// - 弹 GUI 让用户选安装路径
// - 解压 zip → 创建开始菜单/桌面快捷方式 → 启动 app
// - 卸载逻辑：删除安装目录 + 清理快捷方式 + 清理注册表

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

namespace TVBoxInstaller
{
    public class MainForm : Form
    {
        // UI 控件
        private Label titleLabel;
        private Label pathLabel;
        private TextBox pathTextBox;
        private Button browseButton;
        private CheckBox desktopShortcutCheckBox;
        private CheckBox startMenuShortcutCheckBox;
        private CheckBox launchAfterInstallCheckBox;
        private Button installButton;
        private Button cancelButton;
        private ProgressBar progressBar;
        private Label statusLabel;
        private Label diskSpaceLabel;

        // 应用元数据
        private const string AppName = "TVBox";
        private const string ExeName = "tvbox.exe";
        private const string Publisher = "dom";
        private const string AppId = "5ef970f9-2b9e-4155-b7d6-a9d4dbd6b227";
        // 内嵌资源名（由 csc /resource:app.zip,app.zip 提供）
        private const string EmbeddedZipResource = "app.zip";

        public MainForm()
        {
            InitializeUI();
            // 默认路径：C:\Users\<user>\TVBox（用户可改，永远不默认到 C:\Program Files\）
            string defaultPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                AppName
            );
            pathTextBox.Text = defaultPath;
            UpdateDiskSpaceInfo();
        }

        private void InitializeUI()
        {
            this.Text = AppName + " 安装程序";
            this.Size = new Size(540, 380);
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.MinimizeBox = false;
            this.StartPosition = FormStartPosition.CenterScreen;
            this.Font = new Font("Microsoft YaHei UI", 9F);

            int x = 20;
            int w = 500;

            // 标题
            titleLabel = new Label
            {
                Text = "正在安装 " + AppName,
                Font = new Font("Microsoft YaHei UI", 13F, FontStyle.Bold),
                Location = new Point(x, 16),
                Size = new Size(w, 30),
            };

            // 路径标签
            pathLabel = new Label
            {
                Text = "安装路径：",
                Location = new Point(x, 60),
                Size = new Size(80, 20),
            };

            // 路径输入框
            pathTextBox = new TextBox
            {
                Location = new Point(x + 80, 57),
                Size = new Size(330, 23),
            };
            pathTextBox.TextChanged += (s, e) => UpdateDiskSpaceInfo();

            // 浏览按钮
            browseButton = new Button
            {
                Text = "浏览(&B)...",
                Location = new Point(x + 415, 56),
                Size = new Size(75, 25),
            };
            browseButton.Click += BrowseButton_Click;

            // 磁盘空间提示
            diskSpaceLabel = new Label
            {
                Location = new Point(x, 86),
                Size = new Size(w, 18),
                ForeColor = Color.Gray,
            };

            // 选项
            desktopShortcutCheckBox = new CheckBox
            {
                Text = "创建桌面快捷方式(&D)",
                Checked = true,
                Location = new Point(x, 115),
                Size = new Size(250, 20),
            };

            startMenuShortcutCheckBox = new CheckBox
            {
                Text = "创建开始菜单快捷方式(&S)",
                Checked = true,
                Location = new Point(x, 140),
                Size = new Size(280, 20),
            };

            launchAfterInstallCheckBox = new CheckBox
            {
                Text = "安装完成后启动 " + AppName + "(&L)",
                Checked = true,
                Location = new Point(x, 165),
                Size = new Size(280, 20),
            };

            // 进度条
            progressBar = new ProgressBar
            {
                Location = new Point(x, 200),
                Size = new Size(w, 22),
            };

            // 状态标签
            statusLabel = new Label
            {
                Location = new Point(x, 226),
                Size = new Size(w, 18),
                ForeColor = Color.Gray,
                Text = "准备就绪",
            };

            // 按钮
            installButton = new Button
            {
                Text = "安装(&I)",
                Location = new Point(x + 305, 280),
                Size = new Size(90, 32),
            };
            installButton.Click += InstallButton_Click;

            cancelButton = new Button
            {
                Text = "取消(&C)",
                Location = new Point(x + 405, 280),
                Size = new Size(90, 32),
                DialogResult = DialogResult.Cancel,
            };

            this.AcceptButton = installButton;
            this.CancelButton = cancelButton;

            this.Controls.AddRange(new Control[] {
                titleLabel, pathLabel, pathTextBox, browseButton, diskSpaceLabel,
                desktopShortcutCheckBox, startMenuShortcutCheckBox, launchAfterInstallCheckBox,
                progressBar, statusLabel, installButton, cancelButton
            });
        }

        private void UpdateDiskSpaceInfo()
        {
            try
            {
                string target = pathTextBox.Text;
                string root = Path.GetPathRoot(target);
                if (string.IsNullOrEmpty(root) || !Directory.Exists(root))
                {
                    diskSpaceLabel.Text = "";
                    return;
                }
                var drive = new DriveInfo(root);
                long freeGB = drive.AvailableFreeSpace / (1024L * 1024L * 1024L);
                diskSpaceLabel.Text = string.Format("所在磁盘 {0} 剩余空间：{1} GB", drive.Name, freeGB);
                installButton.Enabled = freeGB >= 1; // 至少要 1GB
            }
            catch
            {
                diskSpaceLabel.Text = "";
            }
        }

        private void BrowseButton_Click(object sender, EventArgs e)
        {
            using (var dlg = new FolderBrowserDialog())
            {
                dlg.Description = "请选择 " + AppName + " 的安装文件夹";
                dlg.SelectedPath = pathTextBox.Text;
                dlg.ShowNewFolderButton = true;
                if (dlg.ShowDialog(this) == DialogResult.OK)
                {
                    pathTextBox.Text = dlg.SelectedPath;
                }
            }
        }

        private void InstallButton_Click(object sender, EventArgs e)
        {
            string installPath = pathTextBox.Text.Trim();
            if (string.IsNullOrEmpty(installPath))
            {
                MessageBox.Show(this, "请选择安装路径", "提示", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            try
            {
                Path.GetFullPath(installPath);
            }
            catch
            {
                MessageBox.Show(this, "安装路径无效", "提示", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            // 确认覆盖已有安装
            if (Directory.Exists(installPath) && Directory.Exists(Path.Combine(installPath, "data")))
            {
                var result = MessageBox.Show(
                    this,
                    "检测到该目录已存在 " + AppName + " 安装。\n是否覆盖？",
                    "确认",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question
                );
                if (result != DialogResult.Yes) return;
                try
                {
                    Directory.Delete(installPath, true);
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, "无法删除现有安装：\n" + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }
            }

            // 禁用控件
            installButton.Enabled = false;
            browseButton.Enabled = false;
            pathTextBox.Enabled = false;
            desktopShortcutCheckBox.Enabled = false;
            startMenuShortcutCheckBox.Enabled = false;
            launchAfterInstallCheckBox.Enabled = false;

            // 异步安装
            var worker = new BackgroundWorker();
            worker.WorkerReportsProgress = true;
            worker.DoWork += (s, args) => DoInstall(installPath, worker);
            worker.ProgressChanged += (s, args) =>
            {
                progressBar.Value = Math.Min(args.ProgressPercentage, 100);
                if (args.UserState is string)
                {
                    string msg = (string)args.UserState;
                    statusLabel.Text = msg;
                }
            };
            worker.RunWorkerCompleted += (s, args) =>
            {
                if (args.Error != null)
                {
                    MessageBox.Show(this, "安装失败：\n" + args.Error.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    installButton.Enabled = true;
                    browseButton.Enabled = true;
                    pathTextBox.Enabled = true;
                    desktopShortcutCheckBox.Enabled = true;
                    startMenuShortcutCheckBox.Enabled = true;
                    launchAfterInstallCheckBox.Enabled = true;
                    statusLabel.Text = "安装失败";
                    return;
                }
                bool launch = launchAfterInstallCheckBox.Checked;
                progressBar.Value = 100;
                statusLabel.Text = "安装完成！";
                if (launch)
                {
                    LaunchApp(installPath);
                }
                MessageBox.Show(this, AppName + " 已成功安装到：\n" + installPath, "完成", MessageBoxButtons.OK, MessageBoxIcon.Information);
                this.DialogResult = DialogResult.OK;
                this.Close();
            };
            worker.RunWorkerAsync();
        }

        private void DoInstall(string installPath, BackgroundWorker worker)
        {
            // 1) 写注册表（标记安装信息，给卸载器用）
            worker.ReportProgress(5, "正在准备安装...");
            using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\" + AppId))
            {
                key.SetValue("InstallPath", installPath);
                key.SetValue("Publisher", Publisher);
                key.SetValue("DisplayName", AppName);
                key.SetValue("InstallDate", DateTime.Now.ToString("yyyy-MM-dd"));
            }

            // 2) 创建安装目录
            Directory.CreateDirectory(installPath);

            // 3) 解压嵌入的 app.zip 到安装目录
            worker.ReportProgress(10, "正在解压文件...");
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream zipStream = assembly.GetManifestResourceStream(EmbeddedZipResource))
            {
                if (zipStream == null)
                {
                    throw new InvalidOperationException("未找到内嵌的 app.zip 资源");
                }
                using (var archive = new ZipArchive(zipStream, ZipArchiveMode.Read))
                {
                    int total = archive.Entries.Count;
                    int idx = 0;
                    foreach (var entry in archive.Entries)
                    {
                        idx++;
                        string destPath = Path.Combine(installPath, entry.FullName);
                        // 进度：10% → 85%
                        int percent = 10 + (int)(75.0 * idx / total);
                        if (idx % 20 == 0 || idx == total)
                        {
                            worker.ReportProgress(percent, string.Format("正在解压 ({0}/{1}) {2}", idx, total, entry.FullName));
                        }
                        if (string.IsNullOrEmpty(entry.Name))
                        {
                            Directory.CreateDirectory(destPath);
                        }
                        else
                        {
                            string dir = Path.GetDirectoryName(destPath);
                            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                            entry.ExtractToFile(destPath, true);
                        }
                    }
                }
            }

            // 4) 创建快捷方式
            worker.ReportProgress(88, "正在创建快捷方式...");
            if (startMenuShortcutCheckBox.Checked)
            {
                CreateShortcut(
                    Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.Programs),
                        AppName + ".lnk"
                    ),
                    Path.Combine(installPath, ExeName),
                    installPath
                );
            }
            if (desktopShortcutCheckBox.Checked)
            {
                CreateShortcut(
                    Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.Desktop),
                        AppName + ".lnk"
                    ),
                    Path.Combine(installPath, ExeName),
                    installPath
                );
            }

            // 5) 注册卸载信息
            worker.ReportProgress(95, "正在注册卸载信息...");
            using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + AppId))
            {
                key.SetValue("DisplayName", AppName);
                key.SetValue("Publisher", Publisher);
                key.SetValue("InstallLocation", installPath);
                key.SetValue("DisplayIcon", Path.Combine(installPath, ExeName) + ",0");
                // 卸载命令：用本 exe 启动 --uninstall 模式
                string uninstaller = Assembly.GetExecutingAssembly().Location;
                key.SetValue("UninstallString", "\"" + uninstaller + "\" --uninstall");
                key.SetValue("DisplayVersion", "1.0.0");
                key.SetValue("NoModify", 1);
                key.SetValue("NoRepair", 1);
            }

            worker.ReportProgress(100, "安装完成");
        }

        private void CreateShortcut(string shortcutPath, string targetPath, string workingDir)
        {
            // 用 WScript.Shell COM 创建 .lnk
            Type shellType = Type.GetTypeFromProgID("WScript.Shell");
            object shell = Activator.CreateInstance(shellType);
            object shortcut = shellType.InvokeMember(
                "CreateShortcut",
                BindingFlags.InvokeMethod,
                null,
                shell,
                new object[] { shortcutPath }
            );
            Type shortcutType = shortcut.GetType();
            shortcutType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { targetPath });
            shortcutType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { workingDir });
            shortcutType.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { AppName });
            shortcutType.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
            Marshal.ReleaseComObject(shortcut);
            Marshal.ReleaseComObject(shell);
        }

        private void LaunchApp(string installPath)
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = Path.Combine(installPath, ExeName),
                    WorkingDirectory = installPath,
                    UseShellExecute = true,
                };
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "启动失败：" + ex.Message, "提示", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }
    }

    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            // 静默安装模式（用于自动化测试 / CI）
            if (args.Length > 0 && args[0] == "--silent-install")
            {
                string installPath = args.Length > 1 && !string.IsNullOrEmpty(args[1])
                    ? args[1]
                    : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "TVBox");
                Console.WriteLine("[silent-install] target: " + installPath);
                try
                {
                    if (Directory.Exists(installPath))
                    {
                        Console.WriteLine("[silent-install] cleaning existing install...");
                        Directory.Delete(installPath, true);
                    }
                    // 写注册表
                    using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\5ef970f9-2b9e-4155-b7d6-a9d4dbd6b227"))
                    {
                        key.SetValue("InstallPath", installPath);
                    }
                    Directory.CreateDirectory(installPath);
                    // 解压
                    Assembly assembly = Assembly.GetExecutingAssembly();
                    using (Stream zipStream = assembly.GetManifestResourceStream("app.zip"))
                    {
                        if (zipStream == null) { Console.Error.WriteLine("missing app.zip"); return; }
                        using (var archive = new ZipArchive(zipStream, ZipArchiveMode.Read))
                        {
                            int total = archive.Entries.Count;
                            int idx = 0;
                            foreach (var entry in archive.Entries)
                            {
                                idx++;
                                string destPath = Path.Combine(installPath, entry.FullName);
                                if (string.IsNullOrEmpty(entry.Name))
                                    Directory.CreateDirectory(destPath);
                                else
                                {
                                    string dir = Path.GetDirectoryName(destPath);
                                    if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                                    entry.ExtractToFile(destPath, true);
                                }
                                if (idx % 50 == 0 || idx == total)
                                    Console.WriteLine(string.Format("[silent-install] extracting {0}/{1}", idx, total));
                            }
                        }
                    }
                    Console.WriteLine("[silent-install] OK");
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine("[silent-install] FAILED: " + ex.Message);
                    Environment.Exit(1);
                }
                return;
            }

            // 卸载模式
            if (args.Length > 0 && args[0] == "--uninstall")
            {
                Application.Run(new UninstallerForm());
                return;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    // 卸载器（独立窗口）
    public class UninstallerForm : Form
    {
        private Label titleLabel;
        private Label infoLabel;
        private CheckBox removeDataCheckBox;
        private Button uninstallButton;
        private Button cancelButton;

        public UninstallerForm()
        {
            this.Text = "卸载 " + MainForm_AppName();
            this.Size = new Size(420, 240);
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.MinimizeBox = false;
            this.StartPosition = FormStartPosition.CenterScreen;
            this.Font = new Font("Microsoft YaHei UI", 9F);

            int x = 20;
            titleLabel = new Label
            {
                Text = "卸载 " + MainForm_AppName(),
                Font = new Font("Microsoft YaHei UI", 13F, FontStyle.Bold),
                Location = new Point(x, 16),
                Size = new Size(380, 30),
            };
            infoLabel = new Label
            {
                Text = "将从此计算机移除 " + MainForm_AppName() + "。",
                Location = new Point(x, 56),
                Size = new Size(380, 20),
            };
            removeDataCheckBox = new CheckBox
            {
                Text = "同时删除用户配置与缓存（不可恢复）",
                Checked = false,
                Location = new Point(x, 90),
                Size = new Size(380, 20),
            };
            uninstallButton = new Button
            {
                Text = "卸载(&U)",
                Location = new Point(x + 195, 140),
                Size = new Size(90, 32),
            };
            uninstallButton.Click += UninstallButton_Click;
            cancelButton = new Button
            {
                Text = "取消(&C)",
                Location = new Point(x + 295, 140),
                Size = new Size(90, 32),
                DialogResult = DialogResult.Cancel,
            };
            this.AcceptButton = uninstallButton;
            this.CancelButton = cancelButton;
            this.Controls.AddRange(new Control[] { titleLabel, infoLabel, removeDataCheckBox, uninstallButton, cancelButton });
        }

        private static string MainForm_AppName()
        {
            return "TVBox";
        }

        private void UninstallButton_Click(object sender, EventArgs e)
        {
            uninstallButton.Enabled = false;
            try
            {
                // 读安装路径
                string installPath = null;
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\5ef970f9-2b9e-4155-b7d6-a9d4dbd6b227"))
                {
                    if (key != null) installPath = key.GetValue("InstallPath") as string;
                }
                if (string.IsNullOrEmpty(installPath))
                {
                    MessageBox.Show(this, "找不到安装信息。", "提示", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    this.Close();
                    return;
                }

                // 杀进程
                foreach (var p in Process.GetProcessesByName("tvbox"))
                {
                    try { p.Kill(); p.WaitForExit(3000); } catch { }
                }
                foreach (var p in Process.GetProcessesByName("node"))
                {
                    try { p.Kill(); p.WaitForExit(3000); } catch { }
                }

                // 删快捷方式
                TryDelete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "TVBox.lnk"));
                TryDelete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Desktop), "TVBox.lnk"));

                // 删安装目录
                if (Directory.Exists(installPath))
                {
                    Directory.Delete(installPath, true);
                }

                // 删 AppData 数据
                if (removeDataCheckBox.Checked)
                {
                    string appData = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        "com.pilipala.tvbox"
                    );
                    if (Directory.Exists(appData)) TryDeleteDir(appData);
                    string docs = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                        "nodejs"
                    );
                    if (Directory.Exists(docs)) TryDeleteDir(docs);
                }

                // 清理注册表
                Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(@"Software\5ef970f9-2b9e-4155-b7d6-a9d4dbd6b227", false);
                Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\5ef970f9-2b9e-4155-b7d6-a9d4dbd6b227", false);

                MessageBox.Show(this, "卸载完成。", "完成", MessageBoxButtons.OK, MessageBoxIcon.Information);
                this.Close();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "卸载失败：\n" + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
                uninstallButton.Enabled = true;
            }
        }

        private void TryDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); } catch { }
        }
        private void TryDeleteDir(string path)
        {
            try { Directory.Delete(path, true); } catch { }
        }
    }
}
