import picker from '@ohos.file.picker';
import promptAction from '@ohos.promptAction';
import deviceInfo from '@ohos.deviceInfo';
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import { Plugin, Invoke } from '@tauri/app';

interface FileFilter {
  name?: string;
  extensions?: string[];
}

interface OpenArgs {
  multiple?: boolean;
  directory?: boolean;
  filters?: FileFilter[];
  defaultPath?: string;
  title?: string;
}

interface SaveArgs {
  filters?: FileFilter[];
  defaultPath?: string;
  title?: string;
  fileName?: string;
}

interface MessageArgs {
  title?: string;
  message?: string;
  type?: string;
  okButtonLabel?: string;
  noButtonLabel?: string;
  cancelButtonLabel?: string;
}

export class DialogPlugin extends Plugin {
  getCommands(): Map<string, (invoke: Invoke) => void> {
    const commands: Map<string, (invoke: Invoke) => void> = new Map();
    commands.set('showFilePicker', (invoke: Invoke): void => { this.handleOpen(invoke); });
    commands.set('saveFileDialog', (invoke: Invoke): void => { this.handleSave(invoke); });
    commands.set('showMessageDialog', (invoke: Invoke): void => { this.handleMessage(invoke); });
    return commands;
  }

  private handleOpen(invoke: Invoke): void {
    const argsStr = invoke.parseArgs();
    console.info('[DialogPlugin] showFilePicker args: ' + argsStr);
    const args: OpenArgs = JSON.parse(argsStr) as OpenArgs;
    const multiple = args.multiple ?? false;
    const directory = args.directory ?? false;
    this.showDocumentPicker(invoke, multiple, directory);
  }

  private handleSave(invoke: Invoke): void {
    const argsStr = invoke.parseArgs();
    console.info('[DialogPlugin] saveFileDialog args: ' + argsStr);
    const args: SaveArgs = JSON.parse(argsStr) as SaveArgs;
    const fileName = args.fileName ?? 'untitled';
    this.showSavePicker(invoke, fileName);
  }

  private handleMessage(invoke: Invoke): void {
    const argsStr = invoke.parseArgs();
    console.info('[DialogPlugin] showMessageDialog args: ' + argsStr);
    const args: MessageArgs = JSON.parse(argsStr) as MessageArgs;
    const title = args.title ?? '';
    const message = args.message ?? '';
    const buttons: string[] = [];
    if (args.okButtonLabel != null) {
      buttons.push(args.okButtonLabel);
    }
    if (args.noButtonLabel != null) {
      buttons.push(args.noButtonLabel);
    }
    if (args.cancelButtonLabel != null) {
      buttons.push(args.cancelButtonLabel);
    }
    if (buttons.length === 0) {
      buttons.push('OK');
    }
    this.showMessageBox(invoke, title, message, buttons);
  }

  private async showDocumentPicker(invoke: Invoke, multiple: boolean, directory: boolean): Promise<void> {
    try {
      console.info('[DialogPlugin] showDocumentPicker multiple=' + multiple + ' directory=' + directory);
      const documentPicker = new picker.DocumentViewPicker();
      const options: picker.DocumentSelectOptions = {
        maxSelectNumber: multiple ? 10 : 1
      };

      // Folder selection (Eulogizethesun/tauri#99): DocumentViewPicker has no
      // dedicated folder mode — selectMode decides what can be picked.
      // - 2in1 (PC): MIXED is the only mode that works there (files and
      //   folders mixed; per official docs MIXED has no effect on other
      //   devices).
      // - Phone: FOLDER requires API 26+; older versions get an explicit
      //   error instead of a silent empty result.
      if (directory) {
        if (deviceInfo.deviceType === '2in1') {
          options.selectMode = picker.DocumentSelectMode.MIXED;
        } else {
          if (deviceInfo.sdkApiVersion < 26) {
            console.error('[DialogPlugin] folder picking requires API 26+ on non-2in1 devices, current ' + deviceInfo.sdkApiVersion);
            invoke.reject('Folder picking is not supported on this device (FOLDER selectMode requires API 26+, current ' + deviceInfo.sdkApiVersion + ')');
            return;
          }
          options.selectMode = picker.DocumentSelectMode.FOLDER;
        }
      }

      const result = await documentPicker.select(options);
      console.info('[DialogPlugin] documentPicker result: ' + JSON.stringify(result));
      if (result && result.length > 0) {
        // MIXED mode on 2in1 lets the user select files alongside folders
        // (Eulogizethesun/tauri#124): drop file URIs instead of returning
        // them as picked folders. Idempotent for Phone's FOLDER mode, which
        // cannot select files in the first place.
        let selected: string[] = result;
        if (directory) {
          selected = [];
          for (const uri of result) {
            if (this.isDirectoryUri(uri)) {
              selected.push(uri);
            } else {
              console.warn('[DialogPlugin] directory picker dropping non-directory URI: ' + uri);
            }
          }
        }
        if (selected.length > 0) {
          invoke.resolve(JSON.stringify({ files: selected }));
        } else {
          // Mirror the cancel branch below: never resolve an empty files
          // array — the Rust side unwraps the first element and would panic.
          invoke.reject('File picker cancelled');
        }
      } else {
        invoke.reject('File picker cancelled');
      }
    } catch (e) {
      const err = e as Error;
      console.error('[DialogPlugin] showDocumentPicker error: ' + err.message);
      invoke.reject('Document picker failed: ' + err.message);
    }
  }

  // Checks whether a picker-returned URI points to a directory
  // (Eulogizethesun/tauri#124).
  // - API 22+: fs.statSync accepts URIs directly, so Stat.isDirectory()
  //   decides.
  // - API < 22: FileUri.getFullDirectoryUri() (since 11) returns the
  //   containing directory URI when the URI points to a file and the URI
  //   itself unchanged when it points to a directory, so equality means the
  //   URI is a directory.
  // A failed check counts as a non-directory: the caller drops the entry
  // rather than returning a file as a picked folder.
  private isDirectoryUri(uri: string): boolean {
    if (deviceInfo.sdkApiVersion >= 22) {
      try {
        return fs.statSync(uri).isDirectory();
      } catch {
        return false;
      }
    }
    try {
      return new fileUri.FileUri(uri).getFullDirectoryUri() === uri;
    } catch {
      return false;
    }
  }

  private async showSavePicker(invoke: Invoke, fileName: string): Promise<void> {
    try {
      console.info('[DialogPlugin] showSavePicker fileName=' + fileName);
      const documentPicker = new picker.DocumentViewPicker();
      const options: picker.DocumentSaveOptions = {
        newFileNames: [fileName]
      };

      const result = await documentPicker.save(options);
      console.info('[DialogPlugin] savePicker result: ' + JSON.stringify(result));
      if (result && result.length > 0) {
        invoke.resolve(JSON.stringify({ file: result[0] }));
      } else {
        invoke.reject('Save cancelled');
      }
    } catch (e) {
      const err = e as Error;
      console.error('[DialogPlugin] showSavePicker error: ' + err.message);
      invoke.reject('Save picker failed: ' + err.message);
    }
  }

  private async showMessageBox(invoke: Invoke, title: string, message: string, buttons: string[]): Promise<void> {
    try {
      console.info('[DialogPlugin] showMessageBox title=' + title + ', message=' + message);
      const buttonOptions: promptAction.Button[] = buttons.map((text: string): promptAction.Button => {
        return { text: text, color: '#1890FF' };
      });

      const result = await promptAction.showDialog({
        title: title,
        message: message,
        buttons: buttonOptions
      });

      const buttonText = buttons[result.index];
      console.info('[DialogPlugin] messageBox result: ' + buttonText);
      invoke.resolve(JSON.stringify({ value: buttonText }));
    } catch (e) {
      const err = e as Error;
      console.error('[DialogPlugin] showMessageBox error: ' + err.message);
      invoke.reject('Message box failed: ' + err.message);
    }
  }
}

export default DialogPlugin;