import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import 'agent_state_manager.dart';
import 'chat_screen.dart';
import 'git_info.dart';
import 'models.dart';
import 'pi_rpc_client.dart';
import 'project_manager.dart';
import 'sidebar_panel.dart';

/// Main desktop shell: persistent sidebar on the left + chat in the center +
/// a compact status bar at the bottom.
///
/// The sidebar can be toggled open/closed via a button in the top toolbar.
class ShellScreen extends StatefulWidget {
  final String? initialCwd;
  final dynamic appThemeState;

  const ShellScreen({
    super.key,
    this.initialCwd,
    this.appThemeState,
  });

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  late final PiRpcClient _client;
  late final AgentStateManager _stateManager;
  bool _ready = false;
  bool _sidebarOpen = true;

  // Shared state
  List<Model> _models = [];
  Model? _currentModel;
  String _currentThinkingLevel = '';
  String? _gitBranch;
  bool _isGitRepo = false;

  /// Key to control the ChatContent widget (reset, loadSession).
  final _chatKey = GlobalKey<ChatContentState>();

  @override
  void initState() {
    super.initState();
    _client = PiRpcClient();
    _stateManager = AgentStateManager(client: _client);
    _stateManager.addListener(_onStateChange);
    _initClient();
  }

  @override
  void dispose() {
    _stateManager.removeListener(_onStateChange);
    _stateManager.dispose();
    _client.dispose();
    super.dispose();
  }

  void _onStateChange() {
    if (mounted) setState(() {});
  }

  Future<void> _initClient() async {
    if (widget.initialCwd != null) {
      _client.updateCwd(widget.initialCwd!);
    }
    await _client.start();
    await _fetchModelsAndState();
    await _updateGitInfo();
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _fetchModelsAndState() async {
    final modelsRes = await _client.getAvailableModels();
    final stateRes = await _client.getState();
    if (mounted) {
      setState(() {
        if (modelsRes?.success == true && modelsRes?.data != null) {
          final rawModels = modelsRes!.data!['models'] as List<dynamic>?;
          _models = rawModels
                  ?.map((m) => Model.fromJson(m as Map<String, dynamic>))
                  .toList() ??
              [];
        }
        if (stateRes?.success == true && stateRes?.data != null) {
          final state = AgentState.fromJson(stateRes!.data!);
          _currentModel = state.model;
          _currentThinkingLevel = state.thinkingLevel ?? '';
        }
      });
    }
  }

  Future<void> _updateGitInfo() async {
    final branch = await GitInfo.getBranch(_client.cwd);
    final isRepo = await GitInfo.isGitRepo(_client.cwd);
    if (mounted) {
      setState(() {
        _gitBranch = branch;
        _isGitRepo = isRepo;
      });
    }
  }

  // ── Directory / project switching ──────────────────────────────────────

  Future<void> _changeDirectory() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select working directory',
      initialDirectory: _client.cwd,
    );

    if (picked == null || picked.trim().isEmpty) return;

    final dir = Directory(picked.trim());
    if (!await dir.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Directory does not exist')),
        );
      }
      return;
    }

    await _switchToDirectory(dir.path);
  }

  Future<void> _switchToDirectory(String path) async {
    setState(() => _ready = false);

    await ProjectManager.setLastCwd(path);
    _client.updateCwd(path);
    await _client.restart(path);
    await _fetchModelsAndState();
    await _updateGitInfo();

    if (mounted) {
      setState(() => _ready = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _chatKey.currentState?.reset();
      });
    }
  }

  Future<void> _loadSession(String sessionPath) async {
    setState(() => _ready = false);

    await _client.restart(_client.cwd, sessionPath: sessionPath);
    await _fetchModelsAndState();

    if (mounted) {
      setState(() => _ready = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _chatKey.currentState?.loadSession(sessionPath);
      });
    }
  }

  Future<void> _newChat() async {
    if (mounted) {
      final chatState = _chatKey.currentState;
      final hasMessages = chatState?.hasMessages ?? false;

      if (hasMessages) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Start a new chat?'),
            content: const Text(
              'The current conversation will be saved and available in session history.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('New Chat'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }

      setState(() => _ready = false);

      // Try using new_session command first, fall back to restart
      final res = await _client.newSession();
      if (res?.success != true) {
        await _client.restart(_client.cwd);
      }
      await _fetchModelsAndState();
      await _updateGitInfo();

      if (mounted) {
        setState(() => _ready = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _chatKey.currentState?.reset();
        });
      }
    }
  }

  // ── Theme ──────────────────────────────────────────────────────────────

  void _cycleTheme() {
    final state = widget.appThemeState;
    if (state == null) return;
    final current = state.themeMode as ThemeMode;
    ThemeMode next;
    switch (current) {
      case ThemeMode.system:
        next = ThemeMode.light;
        break;
      case ThemeMode.light:
        next = ThemeMode.dark;
        break;
      case ThemeMode.dark:
        next = ThemeMode.system;
        break;
    }
    state.setThemeMode(next);
  }

  // ── Model selection ────────────────────────────────────────────────────

  Future<void> _selectModel(Model model) async {
    final res = await _client.setModel(model.provider, model.id);
    if (res?.success == true && res?.data != null) {
      if (mounted) {
        setState(() => _currentModel = Model.fromJson(res!.data!));
      }
    }
  }

  Future<void> _cycleModel() async {
    final res = await _client.cycleModel();
    if (res?.success == true && res?.data != null) {
      final modelData = res!.data!['model'] as Map<String, dynamic>?;
      if (modelData != null && mounted) {
        setState(() {
          _currentModel = Model.fromJson(modelData);
          _currentThinkingLevel = res.data!['thinkingLevel'] as String? ?? '';
        });
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;

    // Auto-collapse on narrow screens
    final effectiveSidebarOpen = screenWidth < 800 ? false : _sidebarOpen;

    return Scaffold(
      body: Column(
        children: [
          // ── Top toolbar ──────────────────────────────────────────
          _TopToolbar(
            sidebarOpen: effectiveSidebarOpen,
            onToggleSidebar: () => setState(() => _sidebarOpen = !_sidebarOpen),
            client: _client,
            ready: _ready,
            currentModel: _currentModel,
            models: _models,
            thinkingLevel: _currentThinkingLevel,
            gitBranch: _gitBranch,
            isGitRepo: _isGitRepo,
            onSelectModel: _selectModel,
            onCycleModel: _cycleModel,
            onCycleTheme: _cycleTheme,
            onNewChat: _newChat,
            onChangeDirectory: _changeDirectory,
          ),

          // ── Main area: sidebar + chat ────────────────────────────
          Expanded(
            child: Row(
              children: [
                // Left sidebar
                if (effectiveSidebarOpen)
                  SidebarPanel(
                    client: _client,
                    stateManager: _stateManager,
                    gitBranch: _gitBranch,
                    isGitRepo: _isGitRepo,
                    onProjectSelected: (path) {
                      if (path != _client.cwd) _switchToDirectory(path);
                    },
                    onSessionSelected: _loadSession,
                    onNewChat: _newChat,
                    onCycleTheme: _cycleTheme,
                  ),

                // Thin divider when sidebar is open
                if (effectiveSidebarOpen)
                  Container(width: 1, color: cs.outlineVariant),

                // Main chat area
                Expanded(
                  child: _ready
                      ? ChatContent(
                          key: _chatKey,
                          client: _client,
                          stateManager: _stateManager,
                        )
                      : _buildLoading(cs),
                ),
              ],
            ),
          ),

          // ── Status bar ───────────────────────────────────────────
          _StatusBar(
            client: _client,
            stateManager: _stateManager,
            gitBranch: _gitBranch,
            isGitRepo: _isGitRepo,
            currentModel: _currentModel,
            thinkingLevel: _currentThinkingLevel,
            ready: _ready,
          ),
        ],
      ),
    );
  }

  Widget _buildLoading(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 16),
          Text(
            'Starting pi...',
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TOP TOOLBAR
// ═══════════════════════════════════════════════════════════════════════════

class _TopToolbar extends StatelessWidget {
  final bool sidebarOpen;
  final VoidCallback onToggleSidebar;
  final PiRpcClient client;
  final bool ready;
  final Model? currentModel;
  final List<Model> models;
  final String thinkingLevel;
  final String? gitBranch;
  final bool isGitRepo;
  final ValueChanged<Model> onSelectModel;
  final VoidCallback onCycleModel;
  final VoidCallback onCycleTheme;
  final VoidCallback onNewChat;
  final VoidCallback onChangeDirectory;

  const _TopToolbar({
    required this.sidebarOpen,
    required this.onToggleSidebar,
    required this.client,
    required this.ready,
    required this.currentModel,
    required this.models,
    required this.thinkingLevel,
    required this.gitBranch,
    required this.isGitRepo,
    required this.onSelectModel,
    required this.onCycleModel,
    required this.onCycleTheme,
    required this.onNewChat,
    required this.onChangeDirectory,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final modelLabel = currentModel != null
        ? '${currentModel!.name}${thinkingLevel.isNotEmpty ? ' ($thinkingLevel)' : ''}'
        : (ready ? 'No model' : 'Loading...');

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant, width: 1),
        ),
      ),
      child: Row(
        children: [
          // Sidebar toggle
          IconButton(
            icon: Icon(
              sidebarOpen ? Icons.menu_open : Icons.menu,
              size: 20,
            ),
            tooltip: sidebarOpen ? 'Close sidebar' : 'Open sidebar',
            onPressed: onToggleSidebar,
            visualDensity: VisualDensity.compact,
          ),

          const SizedBox(width: 8),

          // Current directory badge
          const SizedBox(width: 8),
          GestureDetector(
            onTap: ready ? onChangeDirectory : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder, size: 13, color: cs.primary),
                  const SizedBox(width: 4),
                  Text(
                    client.cwd.split('/').last,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  if (isGitRepo && gitBranch != null) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 1,
                      height: 12,
                      color: cs.outlineVariant,
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.call_split, size: 11, color: cs.primary),
                    const SizedBox(width: 3),
                    Text(
                      gitBranch!,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const Spacer(),

          // Model selector
          if (models.isNotEmpty)
            PopupMenuButton<Model>(
              tooltip: 'Select model',
              onSelected: onSelectModel,
              offset: const Offset(0, 40),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.outlineVariant),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.smart_toy_outlined,
                        size: 14, color: cs.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      modelLabel,
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.arrow_drop_down,
                        size: 16, color: cs.onSurfaceVariant),
                  ],
                ),
              ),
              itemBuilder: (ctx) {
                final popupCs = Theme.of(ctx).colorScheme;
                return models.map((m) {
                  final isSelected = currentModel != null &&
                      m.provider == currentModel!.provider &&
                      m.id == currentModel!.id;
                  return PopupMenuItem<Model>(
                    value: m,
                    child: Row(
                      children: [
                        Icon(
                          isSelected
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          size: 16,
                          color: isSelected
                              ? popupCs.tertiary
                              : popupCs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            m.name,
                            style: TextStyle(
                              fontWeight:
                                  isSelected ? FontWeight.bold : FontWeight.normal,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Text(
                          m.provider,
                          style: TextStyle(
                            fontSize: 11,
                            color: popupCs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList();
              },
            ),

          const SizedBox(width: 4),

          // Cycle model
          IconButton(
            icon: const Icon(Icons.swap_horiz, size: 20),
            tooltip: 'Cycle model',
            onPressed: ready ? onCycleModel : null,
            visualDensity: VisualDensity.compact,
          ),

          // New chat
          IconButton(
            icon: const Icon(Icons.add_comment_outlined, size: 20),
            tooltip: 'New chat',
            onPressed: ready ? onNewChat : null,
            visualDensity: VisualDensity.compact,
          ),

          // Theme toggle
          IconButton(
            icon: Icon(
              theme.brightness == Brightness.dark
                  ? Icons.dark_mode
                  : Icons.light_mode,
              size: 20,
            ),
            tooltip: 'Toggle theme',
            onPressed: onCycleTheme,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// STATUS BAR
// ═══════════════════════════════════════════════════════════════════════════

class _StatusBar extends StatelessWidget {
  final PiRpcClient client;
  final AgentStateManager stateManager;
  final String? gitBranch;
  final bool isGitRepo;
  final Model? currentModel;
  final String thinkingLevel;
  final bool ready;

  const _StatusBar({
    required this.client,
    required this.stateManager,
    required this.gitBranch,
    required this.isGitRepo,
    required this.currentModel,
    required this.thinkingLevel,
    required this.ready,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final cwd = client.cwd;

    final parts = cwd.split('/');
    final displayPath = parts.length > 3
        ? '…/${parts.sublist(parts.length - 3).join('/')}'
        : cwd;

    final statuses = stateManager.statuses.entries.toList();

    return Container(
      height: statuses.isEmpty ? 28 : null,
      constraints: const BoxConstraints(minHeight: 28),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        border: Border(
          top: BorderSide(color: cs.outlineVariant, width: 1),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Directory
              Icon(Icons.folder, size: 12, color: cs.primary),
              const SizedBox(width: 4),
              Flexible(
                child: Tooltip(
                  message: cwd,
                  child: Text(
                    displayPath,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),

              // Git branch
              if (isGitRepo && gitBranch != null) ...[
                const SizedBox(width: 8),
                Container(width: 1, height: 14, color: cs.outlineVariant),
                const SizedBox(width: 8),
                Icon(Icons.call_split, size: 11, color: cs.primary),
                const SizedBox(width: 3),
                Text(
                  gitBranch!,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
              ],

              const Spacer(),

              // Extension statuses
              if (statuses.isNotEmpty)
                ...statuses.take(3).map((entry) {
                  return Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: cs.secondaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      entry.value,
                      style: TextStyle(
                        fontSize: 9,
                        color: cs.onSecondaryContainer,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }),

              const SizedBox(width: 8),

              // Connection status
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: ready ? cs.tertiary : cs.error,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                ready ? 'Connected' : 'Disconnected',
                style: TextStyle(
                  fontSize: 10,
                  color: ready ? cs.tertiary : cs.error,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
