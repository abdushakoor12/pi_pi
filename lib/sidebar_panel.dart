import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import 'agent_state_manager.dart';
import 'models.dart';
import 'pi_rpc_client.dart';
import 'project_manager.dart';
import 'session_manager.dart';

/// A collapsing left-sidebar with tabs: Projects, History, Commands, Settings.
///
/// Each project/history entry can be closed (removed) via an X button.
class SidebarPanel extends StatefulWidget {
  final PiRpcClient client;
  final AgentStateManager stateManager;
  final String? gitBranch;
  final bool isGitRepo;

  /// Called when the user picks a project to switch to.
  final ValueChanged<String> onProjectSelected;

  /// Called when the user picks a session to load.
  final ValueChanged<String> onSessionSelected;

  /// Called when a new chat should be started.
  final VoidCallback onNewChat;

  /// Called to cycle the theme.
  final VoidCallback onCycleTheme;

  const SidebarPanel({
    super.key,
    required this.client,
    required this.stateManager,
    this.gitBranch,
    required this.isGitRepo,
    required this.onProjectSelected,
    required this.onSessionSelected,
    required this.onNewChat,
    required this.onCycleTheme,
  });

  @override
  State<SidebarPanel> createState() => _SidebarPanelState();
}

class _SidebarPanelState extends State<SidebarPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<String> _projects = [];
  List<SessionSummary> _sessions = [];
  List<CommandInfo> _commands = [];
  List<ForkMessage> _forkMessages = [];
  String? _lastCwd;
  String? _sessionName;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _lastCwd = widget.client.cwd;
    _loadProjects();
    _loadSessions();
    _loadCommands();
    _loadForkMessages();
    _refreshSessionName();
    widget.stateManager.addListener(_onStateChange);
  }

  @override
  void didUpdateWidget(SidebarPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.client.cwd != _lastCwd) {
      _lastCwd = widget.client.cwd;
      _loadProjects();
      _loadSessions();
      _loadCommands();
      _loadForkMessages();
      _refreshSessionName();
    }
  }

  @override
  void dispose() {
    widget.stateManager.removeListener(_onStateChange);
    _tabController.dispose();
    super.dispose();
  }

  void _onStateChange() {
    final newName = widget.stateManager.agentState?.sessionName;
    if (newName != _sessionName) {
      setState(() => _sessionName = newName);
    }
  }

  Future<void> _loadProjects() async {
    final projects = await ProjectManager.getProjects();
    if (mounted) setState(() => _projects = projects);
  }

  Future<void> _loadSessions() async {
    final sessions = await SessionManager.listSessions(widget.client.cwd);
    if (mounted) setState(() => _sessions = sessions);
  }

  Future<void> _loadCommands() async {
    final res = await widget.client.getCommands();
    if (res?.success == true && res?.data != null) {
      final cmds = res!.data!['commands'] as List<dynamic>?;
      if (cmds != null && mounted) {
        setState(() => _commands = cmds
            .map((c) => CommandInfo.fromJson(c as Map<String, dynamic>))
            .toList());
      }
    }
  }

  Future<void> _loadForkMessages() async {
    final res = await widget.client.getForkMessages();
    if (res?.success == true && res?.data != null) {
      final msgs = res!.data!['messages'] as List<dynamic>?;
      if (msgs != null && mounted) {
        setState(() => _forkMessages = msgs
            .map((m) => ForkMessage.fromJson(m as Map<String, dynamic>))
            .toList());
      }
    }
  }

  Future<void> _refreshSessionName() async {
    await widget.stateManager.refreshState();
  }

  Future<void> _setSessionName() async {
    final controller = TextEditingController(text: _sessionName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Session Name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter session name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await widget.client.setSessionName(name);
      await _refreshSessionName();
    }
  }

  Future<void> _forkSession(String entryId) async {
    final res = await widget.client.fork(entryId);
    if (res?.success == true && res?.data != null) {
      final cancelled = res!.data!['cancelled'] as bool? ?? false;
      if (!cancelled && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Forked session')),
        );
        _loadSessions();
      }
    }
  }

  Future<void> _cloneSession() async {
    final res = await widget.client.clone();
    if (res?.success == true && res?.data != null) {
      final cancelled = res!.data!['cancelled'] as bool? ?? false;
      if (!cancelled && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cloned session')),
        );
        _loadSessions();
      }
    }
  }

  Future<void> _addProject() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select a directory to add as project',
      initialDirectory: widget.client.cwd,
    );
    if (picked == null) return;
    await ProjectManager.addProject(picked);
    await _loadProjects();
  }

  Future<void> _removeProject(String path) async {
    await ProjectManager.removeProject(path);
    await _loadProjects();
  }

  String _dirName(String path) {
    try {
      return path.split('/').last;
    } catch (_) {
      return path;
    }
  }

  IconData _iconForPath(String path) {
    if (File('$path/pubspec.yaml').existsSync()) return Icons.flutter_dash;
    if (File('$path/package.json').existsSync()) return Icons.javascript;
    if (Directory('$path/.git').existsSync()) return Icons.code;
    return Icons.folder;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(
          right: BorderSide(color: cs.outlineVariant, width: 1),
        ),
      ),
      child: Column(
        children: [
          // ── Sidebar header ────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: cs.outlineVariant, width: 1),
              ),
            ),
            child: Row(
              children: [
                const Spacer(),
                // Session name button
                if (_sessionName != null)
                  Tooltip(
                    message: _sessionName!,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 120),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _sessionName!,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: cs.onPrimaryContainer,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                _SmallIconButton(
                  icon: Icons.edit,
                  tooltip: 'Set session name',
                  onPressed: _setSessionName,
                ),
                const SizedBox(width: 4),
                // New chat
                _SmallIconButton(
                  icon: Icons.add_comment_outlined,
                  tooltip: 'New chat',
                  onPressed: widget.onNewChat,
                ),
                const SizedBox(width: 4),
                // Theme toggle
                _SmallIconButton(
                  icon: theme.brightness == Brightness.dark
                      ? Icons.dark_mode
                      : Icons.light_mode,
                  tooltip: 'Toggle theme',
                  onPressed: widget.onCycleTheme,
                ),
              ],
            ),
          ),

          // ── Current directory info ────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: cs.outlineVariant, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.folder, size: 14, color: cs.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Tooltip(
                    message: widget.client.cwd,
                    child: Text(
                      widget.client.cwd.split('/').last,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (widget.isGitRepo && widget.gitBranch != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.gitBranch!,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── Tab bar ─────────────────────────────────────────────
          Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: cs.outlineVariant, width: 1),
              ),
            ),
            child: TabBar(
              controller: _tabController,
              labelColor: cs.primary,
              unselectedLabelColor: cs.onSurfaceVariant,
              indicatorColor: cs.primary,
              indicatorWeight: 2,
              labelStyle:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              unselectedLabelStyle: const TextStyle(fontSize: 11),
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                _TabWithBadge(
                  icon: Icons.folder_outlined,
                  label: 'Projects',
                  count: _projects.length,
                ),
                _TabWithBadge(
                  icon: Icons.history,
                  label: 'History',
                  count: _sessions.length,
                ),
                _TabWithBadge(
                  icon: Icons.terminal,
                  label: 'Cmds',
                  count: _commands.length,
                ),
                const Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.settings_outlined, size: 14),
                      SizedBox(width: 4),
                      Text('Settings'),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Tab content ───────────────────────────────────────────
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildProjectsTab(theme, cs),
                _buildHistoryTab(theme, cs),
                _buildCommandsTab(theme, cs),
                _buildSettingsTab(theme, cs),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Projects tab ────────────────────────────────────────────────────────

  Widget _buildProjectsTab(ThemeData theme, ColorScheme cs) {
    return Column(
      children: [
        if (_projects.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_open,
                        size: 40, color: cs.onSurface.withValues(alpha: 0.2)),
                    const SizedBox(height: 12),
                    Text(
                      'No saved projects',
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Add directories to quickly\nswitch between them',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurface.withValues(alpha: 0.35),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _projects.length,
              itemBuilder: (context, index) {
                final path = _projects[index];
                final isActive = path == widget.client.cwd;
                return _ProjectItem(
                  path: path,
                  dirName: _dirName(path),
                  icon: _iconForPath(path),
                  isActive: isActive,
                  onSelect: () => widget.onProjectSelected(path),
                  onRemove: () => _removeProject(path),
                );
              },
            ),
          ),
        // ── Add project button ────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: cs.outlineVariant, width: 0.5),
            ),
          ),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _addProject,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Project', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 6),
                side: BorderSide(color: cs.outlineVariant),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── History tab ─────────────────────────────────────────────────────────

  Widget _buildHistoryTab(ThemeData theme, ColorScheme cs) {
    return Column(
      children: [
        // Fork / Clone buttons
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: cs.outlineVariant, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _forkMessages.isNotEmpty
                      ? () => _showForkDialog()
                      : null,
                  icon: const Icon(Icons.fork_right, size: 14),
                  label: const Text('Fork', style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    side: BorderSide(color: cs.outlineVariant),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _cloneSession,
                  icon: const Icon(Icons.copy, size: 14),
                  label: const Text('Clone', style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    side: BorderSide(color: cs.outlineVariant),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_sessions.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history,
                        size: 40, color: cs.onSurface.withValues(alpha: 0.2)),
                    const SizedBox(height: 12),
                    Text(
                      'No session history',
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Previous chats will appear here',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurface.withValues(alpha: 0.35),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _sessions.length,
              itemBuilder: (context, index) {
                final s = _sessions[index];
                final date = _formatDate(s.timestamp);
                return _SessionItem(
                  title: s.title,
                  date: date,
                  onSelect: () => widget.onSessionSelected(s.path),
                );
              },
            ),
          ),
      ],
    );
  }

  void _showForkDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Fork from message'),
        content: SizedBox(
          width: 400,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _forkMessages.length,
            itemBuilder: (context, index) {
              final msg = _forkMessages[index];
              return ListTile(
                title: Text(
                  msg.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(msg.entryId,
                    style: const TextStyle(fontSize: 10)),
                onTap: () {
                  Navigator.pop(ctx);
                  _forkSession(msg.entryId);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  // ── Commands tab ──────────────────────────────────────────────────────────

  Widget _buildCommandsTab(ThemeData theme, ColorScheme cs) {
    if (_commands.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.terminal,
                  size: 40, color: cs.onSurface.withValues(alpha: 0.2)),
              const SizedBox(height: 12),
              Text(
                'No commands available',
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Extensions, skills, and prompt templates will appear here',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurface.withValues(alpha: 0.35),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _commands.length,
      itemBuilder: (context, index) {
        final cmd = _commands[index];
        final icon = switch (cmd.source) {
          'extension' => Icons.extension,
          'skill' => Icons.psychology,
          _ => Icons.description,
        };
        return ListTile(
          dense: true,
          leading: Icon(icon, size: 16, color: cs.primary),
          title: Text(
            '/${cmd.name}',
            style: const TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: cmd.description != null
              ? Text(
                  cmd.description!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.onSurfaceVariant,
                  ),
                )
              : null,
          onTap: () {
            // Could copy to clipboard or insert into input
          },
        );
      },
    );
  }

  // ── Settings tab ──────────────────────────────────────────────────────────

  Widget _buildSettingsTab(ThemeData theme, ColorScheme cs) {
    final state = widget.stateManager.agentState;
    final stats = widget.stateManager.sessionStats;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // Thinking level
        _SettingsSection(title: 'Thinking', cs: cs),
        _SettingsTile(
          icon: Icons.psychology,
          title: 'Thinking Level',
          subtitle: state?.thinkingLevel ?? 'default',
          onTap: _cycleThinkingLevel,
          cs: cs,
        ),

        // Auto settings
        _SettingsSection(title: 'Automation', cs: cs),
        _SettingsToggle(
          icon: Icons.compress,
          title: 'Auto Compaction',
          value: state?.autoCompactionEnabled ?? false,
          onChanged: (v) => widget.client.setAutoCompaction(v),
          cs: cs,
        ),
        _SettingsToggle(
          icon: Icons.repeat,
          title: 'Auto Retry',
          value: true, // We don't have this in state yet
          onChanged: (v) => widget.client.setAutoRetry(v),
          cs: cs,
        ),

        // Session stats
        if (stats != null) ...[
          _SettingsSection(title: 'Session Stats', cs: cs),
          _StatTile(
            label: 'Messages',
            value: '${stats.totalMessages}',
            cs: cs,
          ),
          _StatTile(
            label: 'Tokens',
            value: '${stats.tokens.total}',
            cs: cs,
          ),
          if (stats.cost != null)
            _StatTile(
              label: 'Cost',
              value: '\$${stats.cost!.toStringAsFixed(4)}',
              cs: cs,
            ),
          if (stats.contextUsage != null)
            _StatTile(
              label: 'Context',
              value: stats.contextUsage!.percent != null
                  ? '${stats.contextUsage!.percent}%'
                  : '${stats.contextUsage!.tokens ?? '?'} / ${stats.contextUsage!.contextWindow ?? '?'}',
              cs: cs,
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: OutlinedButton.icon(
              onPressed: () => widget.stateManager.refreshStats(),
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Refresh Stats', style: TextStyle(fontSize: 11)),
            ),
          ),
        ],

        // Actions
        _SettingsSection(title: 'Actions', cs: cs),
        _SettingsTile(
          icon: Icons.compress,
          title: 'Compact Now',
          subtitle: 'Manually compact conversation',
          onTap: () => widget.client.compact(),
          cs: cs,
        ),
        _SettingsTile(
          icon: Icons.html,
          title: 'Export HTML',
          subtitle: 'Save session as HTML',
          onTap: () => widget.client.exportHtml(),
          cs: cs,
        ),
      ],
    );
  }

  Future<void> _cycleThinkingLevel() async {
    final res = await widget.client.cycleThinkingLevel();
    if (res?.success == true) {
      await widget.stateManager.refreshState();
    }
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final now = DateTime.now();
      if (dt.year == now.year &&
          dt.month == now.month &&
          dt.day == now.day) {
        return 'Today ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
      final yesterday = now.subtract(const Duration(days: 1));
      if (dt.year == yesterday.year &&
          dt.month == yesterday.month &&
          dt.day == yesterday.day) {
        return 'Yesterday ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}

// ── Settings widgets ─────────────────────────────────────────────────────────

class _SettingsSection extends StatelessWidget {
  final String title;
  final ColorScheme cs;

  const _SettingsSection({required this.title, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: cs.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final ColorScheme cs;

  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 18, color: cs.primary),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            )
          : null,
      onTap: onTap,
    );
  }
}

class _SettingsToggle extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final ColorScheme cs;

  const _SettingsToggle({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 18, color: cs.primary),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final ColorScheme cs;

  const _StatTile({required this.label, required this.value, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

// ── Tab with badge ───────────────────────────────────────────────────────────

class _TabWithBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;

  const _TabWithBadge({
    required this.icon,
    required this.label,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 4),
          Text(label),
          if (count > 0) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  color: cs.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Small icon button ────────────────────────────────────────────────────────

class _SmallIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _SmallIconButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        icon: Icon(icon, size: 18),
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

// ── Project list item ───────────────────────────────────────────────────────

class _ProjectItem extends StatelessWidget {
  final String path;
  final String dirName;
  final IconData icon;
  final bool isActive;
  final VoidCallback onSelect;
  final VoidCallback onRemove;

  const _ProjectItem({
    required this.path,
    required this.dirName,
    required this.icon,
    required this.isActive,
    required this.onSelect,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: isActive ? cs.primaryContainer.withValues(alpha: 0.5) : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: isActive ? null : onSelect,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Icon(icon,
                  size: 16,
                  color: isActive ? cs.primary : cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dirName,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            isActive ? FontWeight.bold : FontWeight.w500,
                        color: cs.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      path,
                      style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurface.withValues(alpha: 0.4),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (isActive)
                Container(
                  margin: const EdgeInsets.only(right: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'active',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: cs.onPrimary,
                    ),
                  ),
                ),
              SizedBox(
                width: 24,
                height: 24,
                child: IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  onPressed: onRemove,
                  tooltip: 'Remove project',
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    foregroundColor: cs.onSurfaceVariant.withValues(alpha: 0.6),
                    hoverColor: cs.error.withValues(alpha: 0.1),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Session history list item ───────────────────────────────────────────────

class _SessionItem extends StatelessWidget {
  final String title;
  final String date;
  final VoidCallback onSelect;

  const _SessionItem({
    required this.title,
    required this.date,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onSelect,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.chat_bubble_outline,
                  size: 14, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      date,
                      style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurface.withValues(alpha: 0.4),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 14, color: cs.onSurface.withValues(alpha: 0.3)),
            ],
          ),
        ),
      ),
    );
  }
}
