import path from 'node:path';
let root: string | undefined;
export function configure(directory: string, trusted: boolean) { root = directory; workspace.isTrusted = trusted; }
export const Uri = { file: (file: string) => ({ fsPath: path.resolve(file), scheme: 'file', toString: () => `file://${path.resolve(file)}` }) };
export const workspace = {
  isTrusted: false,
  getWorkspaceFolder: () => root ? { uri: Uri.file(root) } : undefined,
  getConfiguration: () => ({ get: (_name: string, fallback?: unknown) => fallback, inspect: () => ({}) }),
};
const unavailable = () => { throw new Error('Use the native Pandanote interface for this operation.'); };
export const window = {
  createOutputChannel: () => ({ appendLine(value: string) { process.stderr.write(value + '\n'); }, clear() {}, show() {}, dispose() {} }),
  showErrorMessage: unavailable, showInformationMessage: unavailable, showWarningMessage: unavailable,
  showSaveDialog: unavailable, showQuickPick: unavailable, showTextDocument: unavailable, withProgress: unavailable, createTerminal: unavailable,
};
export const commands = { executeCommand: unavailable };
export const ProgressLocation = { Notification: 15 };
