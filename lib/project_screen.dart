import 'dart:io';

import 'package:flutter/material.dart';

import 'project_manager.dart';

/// Full-screen project manager that lists saved directories and allows
/// adding / removing projects.
class ProjectScreen extends StatefulWidget {
  /// The currently active CWD – will be highlighted in the list.
  final String currentCwd;

  /// Called when the user picks a project to open.
  final ValueChanged<String> onProjectSelected;

  const ProjectScreen({
    super.key,
    required this.currentCwd,
    required this.onProjectSelected,
  });

  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  List<String> _projects = [];

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    final projects = await ProjectManager.getProjects();
    setState(() => _projects = projects);
  }

  Future<void> _addCurrent() async {
    await ProjectManager.addProject(widget.currentCwd);
    await _loadProjects();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved "${_dirName(widget.currentCwd)}" as a project'),
        ),
      );
    }
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
    // Determine if the path has a pubspec.yaml → Flutter/Dart project
    if (File('$path/pubspec.yaml').existsSync()) {
      return Icons.flutter_dash;
    }
    if (File('$path/package.json').existsSync()) {
      return Icons.javascript;
    }
    if (Directory('$path/.git').existsSync()) {
      return Icons.code;
    }
    return Icons.folder;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        actions: [
          TextButton.icon(
            onPressed: _addCurrent,
            icon: const Icon(Icons.bookmark_add_outlined, size: 18),
            label: const Text('Save Current'),
          ),
        ],
      ),
      body: _projects.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_open,
                      size: 64, color: theme.colorScheme.primary.withValues(alpha: 0.4)),
                  const SizedBox(height: 16),
                  Text(
                    'No saved projects yet',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Use "Save Current" to add the working directory\nor pick a folder to start working in',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _addCurrent,
                    icon: const Icon(Icons.bookmark_add),
                    label: const Text('Save Current Directory'),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _projects.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final path = _projects[index];
                final isActive = path == widget.currentCwd;
                final dirName = _dirName(path);

                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isActive
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    child: Icon(
                      _iconForPath(path),
                      size: 20,
                      color: isActive
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  title: Text(
                    dirName,
                    style: TextStyle(
                      fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    path,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isActive)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'active',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () => _removeProject(path),
                        tooltip: 'Remove project',
                      ),
                    ],
                  ),
                  onTap: () {
                    if (!isActive) {
                      widget.onProjectSelected(path);
                      Navigator.of(context).pop();
                    }
                  },
                );
              },
            ),
    );
  }
}
