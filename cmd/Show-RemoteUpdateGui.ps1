<#
.SYNOPSIS
    Fleet console for WSUS Offline Update: lists machines, checks that each one
    is online and connectable, and reports what each selected machine actually
    needs before anything is installed.

.DESCRIPTION
    A front end for cmd\Invoke-RemoteUpdate.ps1. Both drive the same transport,
    WsusOfflineRemote.psm1, so a machine behaves identically whether it was
    ticked here or named on the command line.

    The intended order of work is the order the buttons are in:

        Refresh status   read-only. Is the machine up, is its admin share
                         reachable, has it the free space, is a run already in
                         progress on it.
        Scan selected    stage the payload and run cmd\ScanOnly.cmd as SYSTEM.
                         Reports the updates the machine needs and which of
                         those are absent from the download. Installs nothing.
        Install selected the real pass: cmd\DoUpdate.cmd, same as the CLI.
        Clean up         remove payload left behind by "Keep payload staged".

    Applicability is computed on the target, by the Windows Update Agent against
    wsus\wsusscn2.cab, so a scan needs the payload staged just as an install
    does. That is why "Keep payload staged" defaults to on: a scan followed by an
    install then transfers the tree once rather than twice.

    Two honest limitations, both surfaced in the window rather than hidden:

    - A scan reflects the machine as it is now. An install pass applies the
      servicing stack, build upgrades and the WUA itself first, and those can
      make further updates applicable. The count is labelled with the time it
      was taken for that reason.
    - The "not in payload" column is computed from what is staged, which is what
      makes it meaningful - it is ListUpdatesToInstall.cmd's own answer, read
      back out of the log it writes.

    Reboot behaviour matches the CLI exactly: /autoreboot and /shutdown are never
    passed, so no target is restarted and the WOUTempAdmin autologon account is
    never created. A machine that needs a restart is reported as RebootRequired
    and picked up by a later pass.

    Installation options come from client\UpdateInstaller.ini and are shown
    read-only in the status bar. This window is not a second settings editor -
    UpdateInstaller.exe already is one, and two editors for one ini file is how
    they drift apart.

    This machine itself is not listed. Patching the box you are driving from is
    a different operation - it runs in place instead of staging over its own
    admin share - and Invoke-RemoteUpdate.ps1 -IncludeLocalHost does it.

.PARAMETER TargetFile
    Machine list to open at startup. One host per line, blank lines and lines
    starting with # ignored - the same file cmd\Invoke-RemoteUpdate.ps1 takes,
    described in cmd\remote-targets.sample.txt. Defaults to
    cmd\remote-targets.txt if that exists.

.PARAMETER StagingRoot
    Directory on each target to stage into. Defaults to C:\temp.

.PARAMETER Throttle
    How many machines to work on at once. Defaults to 8.

.PARAMETER Credential
    Credentials for the targets. Omit to use the current user.

.PARAMETER TimeoutMinutes
    Per-machine timeout for an install. A scan uses a third of it, with a
    ten-minute floor.

.EXAMPLE
    .\Show-RemoteUpdateGui.ps1

.EXAMPLE
    .\Show-RemoteUpdateGui.ps1 -TargetFile .\remote-targets.txt -Throttle 4
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]       $TargetFile,
    [string]       $StagingRoot = 'C:\temp',
    [ValidateRange(1, 64)]
    [int]          $Throttle = 8,
    [pscredential] $Credential,
    [ValidateRange(1, 1440)]
    [int]          $TimeoutMinutes = 180
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Import-Module (Join-Path $PSScriptRoot 'WsusOfflineRemote.psm1') -Force

$cfg        = Get-WouRemoteConfig
$modulePath = Join-Path $PSScriptRoot 'WsusOfflineRemote.psm1'
$root       = Get-Root
$clientDir  = Join-Path $root 'client'
$iniPath    = Join-Path $clientDir 'UpdateInstaller.ini'
$logDir     = Join-Path (Join-Path $root 'log') 'remote'

if (-not $TargetFile) {
    $default = Join-Path $PSScriptRoot 'remote-targets.txt'
    if (Test-Path -LiteralPath $default) { $TargetFile = $default }
}

# --------------------------------------------------------------- row class --

# A PSCustomObject cannot raise PropertyChanged, so a grid bound to one shows
# the value it had when the row was created and never updates again. Since every
# column here changes while jobs run, the row type has to implement
# INotifyPropertyChanged properly - hence a real class rather than a hashtable.
if (-not ('WouTargetRow' -as [type])) {
    Add-Type -ReferencedAssemblies WindowsBase, System.ObjectModel -TypeDefinition @'
using System;
using System.ComponentModel;

public class WouTargetRow : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler PropertyChanged;
    private void Raise(string name)
    {
        var h = PropertyChanged;
        if (h != null) h(this, new PropertyChangedEventArgs(name));
    }

    private bool _isSelected;
    private string _hostName = "", _conn = "-", _free = "-", _os = "-";
    private string _needs = "-", _missing = "-", _status = "Unknown", _detail = "";
    private string _scanned = "-", _scanPath = "";
    private bool _busy;

    public bool IsSelected { get { return _isSelected; } set { _isSelected = value; Raise("IsSelected"); } }
    public string HostName { get { return _hostName; } set { _hostName = value; Raise("HostName"); } }
    public string Conn     { get { return _conn; }     set { _conn = value;     Raise("Conn"); } }
    public string Free     { get { return _free; }     set { _free = value;     Raise("Free"); } }
    public string Os       { get { return _os; }       set { _os = value;       Raise("Os"); } }
    public string Needs    { get { return _needs; }    set { _needs = value;    Raise("Needs"); } }
    public string Missing  { get { return _missing; }  set { _missing = value;  Raise("Missing"); } }
    public string Status   { get { return _status; }   set { _status = value;   Raise("Status"); } }
    public string Detail   { get { return _detail; }   set { _detail = value;   Raise("Detail"); } }
    public string Scanned  { get { return _scanned; }  set { _scanned = value;  Raise("Scanned"); } }
    public string ScanPath { get { return _scanPath; } set { _scanPath = value; Raise("ScanPath"); } }

    // Guards the buttons: a machine already being worked on is skipped rather
    // than started twice, which would collide on the same staging directory.
    public bool Busy { get { return _busy; } set { _busy = value; Raise("Busy"); } }
}
'@
}

# --------------------------------------------------------------------- xaml --

[xml] $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WSUS Offline Update - fleet console"
        Height="760" Width="1180" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="12">
  <Grid Margin="8">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="0.7*"/>
      <RowDefinition Height="110"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" LastChildFill="True" Margin="0,0,0,6">
      <TextBlock DockPanel.Dock="Left" Text="Machine list:" VerticalAlignment="Center" Margin="0,0,6,0"/>
      <Button   DockPanel.Dock="Right" Name="BtnAdd"    Content="Add..."  Width="70" Margin="4,0,0,0"/>
      <Button   DockPanel.Dock="Right" Name="BtnReload" Content="Reload"  Width="70" Margin="4,0,0,0"/>
      <Button   DockPanel.Dock="Right" Name="BtnBrowse" Content="Browse"  Width="70" Margin="4,0,0,0"/>
      <TextBox  Name="TxtFile" VerticalContentAlignment="Center" Padding="3,2"/>
    </DockPanel>

    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,6">
      <Button Name="BtnStatus"  Content="Refresh status"   Width="120" Height="26"/>
      <Button Name="BtnScan"    Content="Scan selected"    Width="120" Height="26" Margin="6,0,0,0"/>
      <Button Name="BtnInstall" Content="Install selected" Width="120" Height="26" Margin="6,0,0,0"/>
      <Button Name="BtnCancel"  Content="Cancel"           Width="90"  Height="26" Margin="18,0,0,0" IsEnabled="False"/>
      <Button Name="BtnClean"   Content="Clean up staging" Width="120" Height="26" Margin="18,0,0,0"/>
      <Button Name="BtnLogs"    Content="Open log folder"  Width="120" Height="26" Margin="6,0,0,0"/>
    </StackPanel>

    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,6">
      <TextBlock Text="At once:" VerticalAlignment="Center"/>
      <TextBox Name="TxtThrottle" Width="40" Margin="4,0,0,0" VerticalContentAlignment="Center"/>
      <TextBlock Text="Stage into:" VerticalAlignment="Center" Margin="14,0,0,0"/>
      <TextBox Name="TxtStaging" Width="130" Margin="4,0,0,0" VerticalContentAlignment="Center"/>
      <CheckBox Name="ChkKeep" Content="Keep payload staged" IsChecked="True"
                VerticalAlignment="Center" Margin="14,0,0,0"
                ToolTip="Leaves the staged tree on each target so the next pass only transfers what changed. Use Clean up staging to remove it."/>
      <TextBlock Text="Timeout (min):" VerticalAlignment="Center" Margin="14,0,0,0"/>
      <TextBox Name="TxtTimeout" Width="50" Margin="4,0,0,0" VerticalContentAlignment="Center"/>
    </StackPanel>

    <DataGrid Grid.Row="3" Name="GridTargets" AutoGenerateColumns="False" CanUserAddRows="False"
              IsReadOnly="False" SelectionMode="Single" HeadersVisibility="Column"
              GridLinesVisibility="Horizontal" RowHeaderWidth="0" AlternatingRowBackground="#F7F7F7">
      <DataGrid.Columns>
        <DataGridTemplateColumn Width="30" SortMemberPath="IsSelected">
          <DataGridTemplateColumn.Header>
            <CheckBox ToolTip="Tick or untick every machine"/>
          </DataGridTemplateColumn.Header>
          <DataGridTemplateColumn.CellTemplate>
            <DataTemplate>
              <CheckBox IsChecked="{Binding IsSelected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                        HorizontalAlignment="Center"/>
            </DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
        </DataGridTemplateColumn>
        <DataGridTextColumn Header="Machine"  Binding="{Binding HostName}" Width="150" IsReadOnly="True"/>
        <DataGridTextColumn Header="Connect"  Binding="{Binding Conn}"     Width="80"  IsReadOnly="True"/>
        <DataGridTextColumn Header="Free"     Binding="{Binding Free}"     Width="70"  IsReadOnly="True"/>
        <DataGridTextColumn Header="System"   Binding="{Binding Os}"       Width="210" IsReadOnly="True"/>
        <DataGridTextColumn Header="Needs"    Binding="{Binding Needs}"    Width="60"  IsReadOnly="True"/>
        <DataGridTextColumn Header="Missing"  Binding="{Binding Missing}"  Width="65"  IsReadOnly="True"/>
        <DataGridTextColumn Header="Scanned"  Binding="{Binding Scanned}"  Width="80"  IsReadOnly="True"/>
        <DataGridTextColumn Header="Status"   Binding="{Binding Status}"   Width="140" IsReadOnly="True"/>
        <DataGridTextColumn Header="Detail"   Binding="{Binding Detail}"   Width="*"   IsReadOnly="True"/>
      </DataGrid.Columns>
    </DataGrid>

    <TextBlock Grid.Row="4" Name="LblDetail" Margin="0,8,0,4" FontWeight="Bold"
               Text="Select a machine to see the updates its last scan found."/>

    <DataGrid Grid.Row="5" Name="GridUpdates" AutoGenerateColumns="False" CanUserAddRows="False"
              IsReadOnly="True" HeadersVisibility="Column" GridLinesVisibility="Horizontal"
              RowHeaderWidth="0" AlternatingRowBackground="#F7F7F7">
      <DataGrid.Columns>
        <DataGridTextColumn Header="KB"         Binding="{Binding KB}"        Width="90"/>
        <DataGridTextColumn Header="Update ID"  Binding="{Binding UpdateId}"  Width="250"/>
        <DataGridTextColumn Header="In payload" Binding="{Binding State}"     Width="110"/>
        <DataGridTextColumn Header="File"       Binding="{Binding File}"      Width="*"/>
      </DataGrid.Columns>
    </DataGrid>

    <TextBox Grid.Row="6" Name="TxtLog" Margin="0,8,0,0" IsReadOnly="True" AcceptsReturn="True"
             FontFamily="Consolas" FontSize="11" VerticalScrollBarVisibility="Auto"
             TextWrapping="NoWrap" HorizontalScrollBarVisibility="Auto"/>

    <DockPanel Grid.Row="7" Margin="0,8,0,0" LastChildFill="True">
      <ProgressBar DockPanel.Dock="Left" Name="Bar" Width="220" Height="16" Margin="0,0,10,0"/>
      <TextBlock Name="LblStatus" VerticalAlignment="Center" Text="Ready."/>
    </DockPanel>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win    = [Windows.Markup.XamlReader]::Load($reader)

foreach ($name in 'TxtFile', 'BtnBrowse', 'BtnReload', 'BtnAdd', 'BtnStatus', 'BtnScan',
                  'BtnInstall', 'BtnCancel', 'BtnClean', 'BtnLogs', 'TxtThrottle',
                  'TxtStaging', 'ChkKeep', 'TxtTimeout', 'GridTargets', 'LblDetail',
                  'GridUpdates', 'TxtLog', 'Bar', 'LblStatus') {
    Set-Variable -Name $name -Value $win.FindName($name) -Scope Script
}

# -------------------------------------------------------------------- state --

$script:Rows      = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:Updates   = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:Queue     = New-Object System.Collections.Queue
$script:Running   = New-Object System.Collections.Generic.List[object]
$script:Total     = 0
$script:Done      = 0
$script:Cancelling = $false
$script:Flags      = ''
$script:ScanFlags  = ''
$script:PayloadBytes = 0

$GridTargets.ItemsSource = $script:Rows
$GridUpdates.ItemsSource = $script:Updates
$TxtFile.Text     = $TargetFile
$TxtThrottle.Text = "$Throttle"
$TxtStaging.Text  = $StagingRoot
$TxtTimeout.Text  = "$TimeoutMinutes"

# Each job imports the module for itself; Start-Job cannot see the functions
# defined here, which is the same reason Invoke-RemoteUpdate.ps1 does it this way.
$script:StatusWorker = {
    param([string] $ModulePath, [hashtable] $Params)
    Import-Module $ModulePath -Force -ErrorAction Stop
    Test-WouTarget @Params
}
$script:RunWorker = {
    param([string] $ModulePath, [hashtable] $Params)
    Import-Module $ModulePath -Force -ErrorAction Stop
    Invoke-HostRun @Params
}
$script:CleanWorker = {
    param([string] $ModulePath, [hashtable] $Params)
    Import-Module $ModulePath -Force -ErrorAction Stop
    Remove-WouStaging @Params
}
$script:AbortWorker = {
    param([string] $ModulePath, [hashtable] $Params)
    Import-Module $ModulePath -Force -ErrorAction Stop
    Stop-WouRun @Params
}

# ------------------------------------------------------------------ helpers --

function Write-GuiLog {
    param([string] $Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $TxtLog.AppendText($line + [Environment]::NewLine)
    $TxtLog.ScrollToEnd()
}

function Set-GuiState {
    param([bool] $Working)
    foreach ($b in $BtnStatus, $BtnScan, $BtnInstall, $BtnClean, $BtnReload, $BtnBrowse, $BtnAdd) {
        $b.IsEnabled = -not $Working
    }
    $BtnCancel.IsEnabled = $Working
    $TxtThrottle.IsEnabled = -not $Working
    $TxtStaging.IsEnabled  = -not $Working
    $TxtTimeout.IsEnabled  = -not $Working
}

function Get-SelectedRows {
    return @($script:Rows | Where-Object { $_.IsSelected })
}

function Get-GuiThrottle {
    $n = 0
    if (-not [int]::TryParse($TxtThrottle.Text, [ref] $n) -or $n -lt 1 -or $n -gt 64) {
        $n = 8
        $TxtThrottle.Text = '8'
    }
    return $n
}

function Get-GuiTimeout {
    $n = 0
    if (-not [int]::TryParse($TxtTimeout.Text, [ref] $n) -or $n -lt 1 -or $n -gt 1440) {
        $n = 180
        $TxtTimeout.Text = '180'
    }
    return $n
}

function Test-GuiStagingRoot {
    $value = $TxtStaging.Text.Trim()
    # Same two rules the CLI enforces: schtasks /TR takes an unquoted path, and
    # the project itself rejects awkward medium paths (PathValid() in
    # UpdateInstaller.au3), so a bad value is refused here rather than failing
    # obscurely on the target.
    if ($value -match '\s' -or $value -notmatch '^[A-Za-z]:\\') {
        [void] [System.Windows.MessageBox]::Show(
            "Stage into must be a local absolute path on the target with no spaces, e.g. C:\temp.",
            'WSUS Offline Update', 'OK', 'Warning')
        return $null
    }
    return $value
}

function Import-TargetList {
    param([string] $Path)

    $script:Rows.Clear()
    $script:Updates.Clear()
    $LblDetail.Text = 'Select a machine to see the updates its last scan found.'

    if (-not $Path) {
        Write-GuiLog 'No machine list chosen. Use Browse to open one, or Add... to type a name.'
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-GuiLog "Machine list not found: $Path"
        return
    }

    # Resolve-TargetList is the CLI's parser, so the same file behaves the same
    # in both. Its warnings (this machine's own name, for one) belong in the log
    # pane rather than a console nobody is watching.
    $warnings = @()
    $names = Resolve-TargetList -File $Path -WarningVariable warnings -WarningAction SilentlyContinue
    foreach ($w in $warnings) { Write-GuiLog $w.Message }

    foreach ($n in $names) {
        $row = New-Object WouTargetRow
        $row.HostName = $n
        $row.Status   = 'Not checked'
        $script:Rows.Add($row)
    }
    Write-GuiLog ("Loaded {0} machine(s) from {1}" -f $script:Rows.Count, $Path)
    if ($script:Rows.Count -gt 0) { $null = $BtnStatus.Focus() }
}

function Show-RowUpdates {
    param($Row)

    $script:Updates.Clear()
    if (-not $Row) {
        $LblDetail.Text = 'Select a machine to see the updates its last scan found.'
        return
    }
    if (-not $Row.ScanPath -or -not (Test-Path -LiteralPath $Row.ScanPath)) {
        $LblDetail.Text = "$($Row.HostName) - no scan yet. Tick it and press Scan selected."
        return
    }

    $scan = Get-ScanResult -Path $Row.ScanPath
    foreach ($u in $scan.Updates) {
        $state = if ($u.Excluded) {
            "Excluded$(if ($u.Reason) { " ($($u.Reason))" })"
        } elseif ($u.InPayload) {
            'Yes'
        } else {
            'No - not downloaded'
        }
        $script:Updates.Add([pscustomobject]@{
            KB       = $u.KB
            UpdateId = $u.UpdateId
            State    = $state
            File     = if ($u.File) { $u.File } else { '' }
        })
    }

    $LblDetail.Text = ('{0} - {1} applicable, {2} not in the download, {3} excluded (scan taken {4})' -f
        $Row.HostName, $scan.Applicable, $scan.NotInPayload, $scan.Excluded,
        $(if ($scan.ScannedAt) { $scan.ScannedAt } else { 'unknown' }))

    foreach ($w in $scan.Warnings) { Write-GuiLog "[$($Row.HostName)] $w" }
}

function Set-RowFromStatus {
    param($Row, $Info)

    $Row.Conn = if ($Info.AdminShare) { 'SMB' } elseif ($Info.Reachable) { 'ping only' } else { '-' }
    $Row.Free = if ($null -ne $Info.FreeGB) { '{0:N0} GB' -f $Info.FreeGB } else { '-' }
    $Row.Os   = if ($Info.OsCaption) { $Info.OsCaption } else { '-' }

    if ($Info.Busy) {
        $Row.Status = 'Busy'
        $Row.Detail = "$($Info.BusyTask) is already running on this machine."
    } elseif ($Info.AdminShare) {
        $Row.Status = 'Ready'
        $Row.Detail = if ($Info.LastBootUpTime) {
            'Up since {0:yyyy-MM-dd HH:mm}' -f $Info.LastBootUpTime
        } else { '' }
    } elseif ($Info.Reachable) {
        $Row.Status = 'NoAdminShare'
        $Row.Detail = $Info.Note
    } else {
        $Row.Status = 'Unreachable'
        $Row.Detail = $Info.Note
    }
}

function Set-RowFromRun {
    param($Row, $Result, [string] $Kind)

    $Row.Status = $Result.Status
    $Row.Detail = if ($Result.Detail) { $Result.Detail } else { '' }

    if ($Kind -eq 'Scan') {
        if ($Result.ScanPath) { $Row.ScanPath = $Result.ScanPath }
        if ($Result.Scan) {
            $Row.Needs   = "$($Result.Scan.Applicable)"
            $Row.Missing = "$($Result.Scan.NotInPayload)"
            $Row.Scanned = Get-Date -Format 'HH:mm:ss'
        }
    } else {
        # An install changes what is applicable, so the scan columns from before
        # it are no longer true. Saying so is better than showing a stale count.
        $Row.Needs   = '?'
        $Row.Missing = '?'
        $Row.Scanned = 'stale'
        $Row.ScanPath = ''
    }
}

# ------------------------------------------------------------------ the pool --

# The one real hazard in a PowerShell 5.1 GUI: there is no ForEach-Object
# -Parallel, and waiting for jobs on the UI thread freezes the window. So the
# pool is driven from a DispatcherTimer that only ever *asks* - Wait-Job is never
# called here, jobs are polled by state and reaped when they have finished.
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromSeconds(1)

function Add-GuiWork {
    param(
        [Parameter(Mandatory)] $Row,
        [Parameter(Mandatory)][ValidateSet('Status', 'Scan', 'Install', 'Cleanup', 'Abort')]
        [string] $Kind,
        [hashtable] $Params
    )
    $script:Queue.Enqueue([pscustomobject]@{ Row = $Row; Kind = $Kind; Params = $Params })
}

function Start-GuiWork {
    param([string] $Label)

    $script:Total = $script:Queue.Count
    $script:Label = $Label
    $script:Done  = 0
    $script:Cancelling = $false
    if ($script:Total -eq 0) { return }

    $Bar.Maximum = $script:Total
    $Bar.Value   = 0
    $LblStatus.Text = "$Label - 0 of $($script:Total) done"
    Set-GuiState -Working $true
    Write-GuiLog "$Label on $($script:Total) machine(s), $(Get-GuiThrottle) at a time."
    $script:Timer.Start()
}

function Update-GuiProgress {
    param([string] $Label)
    $Bar.Value = $script:Done
    $LblStatus.Text = '{0} - {1} of {2} done, {3} in progress{4}' -f
        $Label, $script:Done, $script:Total, $script:Running.Count,
        $(if ($script:Cancelling) { ', cancelling' } else { '' })
}

$script:TimerTick = {
    $throttle = Get-GuiThrottle

    if (-not $script:Cancelling) {
        while ($script:Queue.Count -gt 0 -and $script:Running.Count -lt $throttle) {
            $item = $script:Queue.Dequeue()
            $worker = switch ($item.Kind) {
                'Status'  { $script:StatusWorker }
                'Cleanup' { $script:CleanWorker }
                'Abort'   { $script:AbortWorker }
                default   { $script:RunWorker }
            }
            $item.Row.Busy = $true
            if ($item.Kind -ne 'Abort') {
                $item.Row.Status = switch ($item.Kind) {
                    'Status'  { 'Checking...' }
                    'Scan'    { 'Scanning...' }
                    'Install' { 'Installing...' }
                    'Cleanup' { 'Cleaning...' }
                }
                $item.Row.Detail = ''
            }
            $job = Start-Job -Name $item.Row.HostName -ScriptBlock $worker `
                             -ArgumentList $script:ModulePath, $item.Params
            $script:Running.Add([pscustomobject]@{ Job = $job; Row = $item.Row; Kind = $item.Kind })
        }
    }

    # ToArray(), never @($list): on a List[object] holding jobs, PowerShell 5.1's
    # array subexpression throws "Argument types do not match". It also gives a
    # snapshot, so removing entries inside the loop is safe.
    foreach ($entry in $script:Running.ToArray()) {
        if ($entry.Job.State -notin 'Completed', 'Failed', 'Stopped') { continue }

        $out = @(Receive-Job -Job $entry.Job -ErrorAction SilentlyContinue)
        $res = $out | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Status'] } |
                   Select-Object -Last 1
        if (-not $res -and $entry.Kind -eq 'Status') {
            $res = $out | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['AdminShare'] } |
                       Select-Object -Last 1
        }
        Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
        $null = $script:Running.Remove($entry)
        $entry.Row.Busy = $false
        $script:Done++

        switch ($entry.Kind) {
            'Status' {
                if ($res) {
                    Set-RowFromStatus -Row $entry.Row -Info $res
                } else {
                    $entry.Row.Status = 'Failed'
                    $entry.Row.Detail = "The check ended without a result ($($entry.Job.State))."
                }
            }
            'Cleanup' {
                if ($res) {
                    $entry.Row.Status = $res.Status
                    $entry.Row.Detail = $res.Detail
                } else {
                    $entry.Row.Status = 'Failed'
                    $entry.Row.Detail = 'Cleanup ended without a result.'
                }
            }
            'Abort' {
                $entry.Row.Status = 'Cancelled'
                $entry.Row.Detail = 'Cancelled by the operator; the task on the machine was ended.'
            }
            default {
                if ($res) {
                    Set-RowFromRun -Row $entry.Row -Result $res -Kind $entry.Kind
                    if ($res.Log) { Write-GuiLog "[$($entry.Row.HostName)] log: $($res.Log)" }
                } else {
                    $entry.Row.Status = 'Failed'
                    $entry.Row.Detail = "The job ended without a result ($($entry.Job.State))."
                }
            }
        }
        Write-GuiLog ('[{0}] {1}{2}' -f $entry.Row.HostName, $entry.Row.Status,
                      $(if ($entry.Row.Detail) { " - $($entry.Row.Detail)" } else { '' }))

        # Keep the lower grid honest about the row the operator is looking at.
        if ($GridTargets.SelectedItem -eq $entry.Row -and $entry.Kind -eq 'Scan') {
            Show-RowUpdates -Row $entry.Row
        }
    }

    Update-GuiProgress -Label $script:Label

    if ($script:Queue.Count -eq 0 -and $script:Running.Count -eq 0) {
        $script:Timer.Stop()
        Set-GuiState -Working $false
        $LblStatus.Text = "$($script:Label) finished - $($script:Done) of $($script:Total) machine(s)."
        Write-GuiLog "$($script:Label) finished."
        $script:Cancelling = $false
    }
}
$script:Timer.Add_Tick($script:TimerTick)

# ----------------------------------------------------------------- commands --

function Measure-Payload {
    if ($script:PayloadBytes -gt 0) { return $script:PayloadBytes }
    $LblStatus.Text = 'Measuring the payload...'
    $win.Dispatcher.Invoke([action] {}, 'Render')
    $measured = Get-ChildItem -LiteralPath $clientDir -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum
    if ($measured) { $script:PayloadBytes = [double]$measured.Sum }
    return $script:PayloadBytes
}

function Test-GuiPayload {
    param([bool] $ForScan)

    if (-not (Test-Path -LiteralPath $clientDir)) {
        [void] [System.Windows.MessageBox]::Show(
            "Client tree not found at '$clientDir'. Run UpdateGenerator first.",
            'WSUS Offline Update', 'OK', 'Error')
        return $false
    }
    $needCmd = if ($ForScan) { 'cmd\ScanOnly.cmd' } else { 'cmd\DoUpdate.cmd' }
    if (-not (Test-Path -LiteralPath (Join-Path $clientDir $needCmd))) {
        [void] [System.Windows.MessageBox]::Show(
            "'$clientDir\$needCmd' not found - is this a complete WSUS Offline tree?",
            'WSUS Offline Update', 'OK', 'Error')
        return $false
    }
    if ($ForScan -and -not (Test-Path -LiteralPath (Join-Path $clientDir 'wsus\wsusscn2.cab'))) {
        [void] [System.Windows.MessageBox]::Show(
            "'$clientDir\wsus\wsusscn2.cab' not found, so there is nothing to scan against. Run a download first.",
            'WSUS Offline Update', 'OK', 'Error')
        return $false
    }
    return $true
}

function Start-GuiRun {
    param([ValidateSet('Scan', 'Install')][string] $Kind)

    $rows = Get-SelectedRows
    if ($rows.Count -eq 0) {
        [void] [System.Windows.MessageBox]::Show('Tick the machines to work on first.',
            'WSUS Offline Update', 'OK', 'Information')
        return
    }
    if (-not (Test-GuiPayload -ForScan ($Kind -eq 'Scan'))) { return }
    $staging = Test-GuiStagingRoot
    if (-not $staging) { return }

    $flags = if ($Kind -eq 'Scan') { $script:ScanFlags } else { $script:Flags }

    if ($Kind -eq 'Install') {
        $answer = [System.Windows.MessageBox]::Show(
            ("Install updates on {0} machine(s)?" -f $rows.Count) + [Environment]::NewLine +
            [Environment]::NewLine +
            "Options: $(if ($flags) { $flags } else { '(none)' })" + [Environment]::NewLine +
            "No machine will be restarted; one that needs it is reported as RebootRequired.",
            'WSUS Offline Update', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }

    if (-not (Test-Path -LiteralPath $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }

    # A scan is bounded by how long the WUA search takes, so it does not need the
    # install timeout - but a slow machine copying a payload still needs room.
    $timeout = Get-GuiTimeout
    if ($Kind -eq 'Scan') { $timeout = [Math]::Max(10, [int]($timeout / 3)) }

    $bytes = Measure-Payload
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    foreach ($row in $rows) {
        if ($row.Busy) { Write-GuiLog "[$($row.HostName)] skipped: already being worked on."; continue }
        Add-GuiWork -Row $row -Kind $Kind -Params @{
            TargetHost     = $row.HostName
            Mode           = $Kind
            PayloadSource  = $clientDir
            StagingRoot    = $staging
            Flags          = $flags
            TimeoutMinutes = $timeout
            PollSeconds    = $cfg.PollSeconds
            KeepPayload    = [bool]$ChkKeep.IsChecked
            PayloadBytes   = $bytes
            LogDir         = $logDir
            Stamp          = $stamp
            Credential     = $Credential
        }
    }
    $script:Label = if ($Kind -eq 'Scan') { 'Scanning' } else { 'Installing updates' }
    Start-GuiWork -Label $script:Label
}

$BtnStatus.Add_Click({
    $rows = Get-SelectedRows
    if ($rows.Count -eq 0) { $rows = @($script:Rows) }
    if ($rows.Count -eq 0) { Write-GuiLog 'No machines loaded.'; return }
    $staging = Test-GuiStagingRoot
    if (-not $staging) { return }

    foreach ($row in $rows) {
        if ($row.Busy) { continue }
        Add-GuiWork -Row $row -Kind 'Status' -Params @{
            ComputerName = $row.HostName
            StagingRoot  = $staging
            Credential   = $Credential
        }
    }
    $script:Label = 'Checking machines'
    Start-GuiWork -Label $script:Label
})

$BtnScan.Add_Click({ Start-GuiRun -Kind 'Scan' })
$BtnInstall.Add_Click({ Start-GuiRun -Kind 'Install' })

$BtnClean.Add_Click({
    $rows = Get-SelectedRows
    if ($rows.Count -eq 0) {
        [void] [System.Windows.MessageBox]::Show('Tick the machines to clean up first.',
            'WSUS Offline Update', 'OK', 'Information')
        return
    }
    $staging = Test-GuiStagingRoot
    if (-not $staging) { return }

    $answer = [System.Windows.MessageBox]::Show(
        ("Remove {0}\{1} from {2} machine(s)?" -f $staging, $cfg.PayloadDir, $rows.Count) +
        [Environment]::NewLine + [Environment]::NewLine +
        "$staging itself is left alone, and a machine with a run still in progress is skipped.",
        'WSUS Offline Update', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    foreach ($row in $rows) {
        if ($row.Busy) { continue }
        $row.ScanPath = ''
        Add-GuiWork -Row $row -Kind 'Cleanup' -Params @{
            ComputerName = $row.HostName
            StagingRoot  = $staging
            Credential   = $Credential
        }
    }
    $script:Label = 'Cleaning up'
    Start-GuiWork -Label $script:Label
})

$BtnCancel.Add_Click({
    if ($script:Cancelling) { return }
    $script:Cancelling = $true

    # Everything not yet started simply never starts.
    $waiting = $script:Queue.Count
    $script:Queue.Clear()

    # Stopping the job only stops this side of it; the scheduled task on the
    # target carries on. So each in-flight machine also gets an explicit /End and
    # /Delete, queued as ordinary work so the UI thread still never blocks.
    $inflight = @()
    foreach ($entry in $script:Running.ToArray()) {
        Stop-Job -Job $entry.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
        $null = $script:Running.Remove($entry)
        $entry.Row.Busy = $false
        if ($entry.Kind -in 'Scan', 'Install') { $inflight += $entry }
    }

    Write-GuiLog ("Cancelled: {0} machine(s) not started, {1} interrupted." -f $waiting, $inflight.Count)
    if ($inflight.Count -eq 0) {
        $script:Timer.Stop()
        Set-GuiState -Working $false
        $LblStatus.Text = 'Cancelled.'
        $script:Cancelling = $false
        return
    }

    foreach ($entry in $inflight) {
        $entry.Row.Status = 'Cancelling...'
        Add-GuiWork -Row $entry.Row -Kind 'Abort' -Params @{
            ComputerName = $entry.Row.HostName
            Mode         = $entry.Kind
            Credential   = $Credential
        }
    }
    # The abort pass is its own batch, so it is allowed to run.
    $script:Cancelling = $false
    $script:Label = 'Cancelling'
    Start-GuiWork -Label $script:Label
})

$BtnBrowse.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title  = 'Open a machine list'
    $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    if ($TxtFile.Text) {
        $dir = Split-Path -Parent $TxtFile.Text
        if ($dir -and (Test-Path -LiteralPath $dir)) { $dlg.InitialDirectory = $dir }
    } else {
        $dlg.InitialDirectory = $PSScriptRoot
    }
    if ($dlg.ShowDialog()) {
        $TxtFile.Text = $dlg.FileName
        Import-TargetList -Path $dlg.FileName
    }
})

$BtnReload.Add_Click({ Import-TargetList -Path $TxtFile.Text.Trim() })

$BtnAdd.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Machine name or IP address:', 'Add a machine', '')
    $name = $name.Trim()
    if (-not $name) { return }

    if (@($script:Rows | Where-Object { $_.HostName -eq $name }).Count -gt 0) {
        Write-GuiLog "$name is already in the list."
        return
    }
    $row = New-Object WouTargetRow
    $row.HostName   = $name
    $row.Status     = 'Not checked'
    $row.IsSelected = $true
    $script:Rows.Add($row)

    # Appending to the file too, so the list the CLI reads and the list on screen
    # do not quietly diverge. Without a file open the row is this session only.
    $path = $TxtFile.Text.Trim()
    if ($path) {
        try {
            Add-Content -LiteralPath $path -Value $name -Encoding Ascii
            Write-GuiLog "Added $name and appended it to $path."
        } catch {
            Write-GuiLog "Added $name to the list, but could not write to $path - $($_.Exception.Message)"
        }
    } else {
        Write-GuiLog "Added $name for this session only; no machine list is open to append it to."
    }
})

$BtnLogs.Add_Click({
    if (-not (Test-Path -LiteralPath $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
    Start-Process -FilePath 'explorer.exe' -ArgumentList $logDir
})

$GridTargets.Add_SelectionChanged({ Show-RowUpdates -Row $GridTargets.SelectedItem })

# The select-all box lives in the first column's header. Reaching it through the
# column rather than FindName is deliberate: names inside a DataGrid column
# header are not reliably registered in the window's name scope.
$headerBox = $GridTargets.Columns[0].Header
if ($headerBox -is [System.Windows.Controls.CheckBox]) {
    $headerBox.Add_Checked({   foreach ($r in $script:Rows) { $r.IsSelected = $true  } })
    $headerBox.Add_Unchecked({ foreach ($r in $script:Rows) { $r.IsSelected = $false } })
}

# The event args are taken from param() rather than $_. PowerShell does set $_ to
# them in a WPF handler, but any pipeline inside the handler replaces it, so
# relying on it makes "close anyway? no" quietly stop working the day someone
# adds a Where-Object above it.
$win.Add_Closing({
    param($EventSender, $CancelArgs)
    if ($script:Running.Count -gt 0 -or $script:Queue.Count -gt 0) {
        $answer = [System.Windows.MessageBox]::Show(
            'Work is still in progress. Close anyway?' + [Environment]::NewLine +
            [Environment]::NewLine +
            'Closing stops the polling but not the tasks already started on the targets. ' +
            'Use Cancel first if you want those ended too.',
            'WSUS Offline Update', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') {
            $CancelArgs.Cancel = $true
            return
        }
    }
    $script:Timer.Stop()
    foreach ($entry in $script:Running.ToArray()) {
        Stop-Job -Job $entry.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
    }
})

# ------------------------------------------------------------------- startup --

Add-Type -AssemblyName Microsoft.VisualBasic

# Read once at startup, and shown rather than editable: UpdateInstaller.exe is
# already the editor for these, and two editors for one ini file is how they
# drift apart. Warnings (a dropped /verify, most often) go to the log pane.
$flagWarnings = @()
$script:Flags = Get-UpdateFlags -IniPath $iniPath -ClientDir $clientDir `
                    -WarningVariable flagWarnings -WarningAction SilentlyContinue
$script:ScanFlags = Get-UpdateFlags -IniPath $iniPath -ClientDir $clientDir -ScanOnly `
                    -WarningVariable +flagWarnings -WarningAction SilentlyContinue

Write-GuiLog "WSUS Offline Update - fleet console. Payload: $clientDir"
Write-GuiLog ("Install options from UpdateInstaller.ini: {0}" -f
              $(if ($script:Flags) { $script:Flags } else { '(none)' }))
Write-GuiLog ("Scan options: {0}" -f
              $(if ($script:ScanFlags) { $script:ScanFlags } else { '(none)' }))
foreach ($w in ($flagWarnings | Select-Object -Unique)) { Write-GuiLog $w.Message }
Write-GuiLog 'Nothing is installed until Install selected is pressed, and no machine is ever restarted.'

$LblStatus.Text = 'Ready. Refresh status first, then Scan selected.'
$win.ToolTip = $null

Import-TargetList -Path $TargetFile

$null = $win.ShowDialog()

# ShowDialog blocks until the window closes, so anything left over is cleaned up
# here rather than in the closing handler, which the window may outlive.
Get-Job -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -and $_.State -in 'Completed', 'Failed', 'Stopped' } |
    Remove-Job -Force -ErrorAction SilentlyContinue
