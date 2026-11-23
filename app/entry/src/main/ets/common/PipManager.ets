import { BuilderNode, NodeController, PiPWindow, typeNode } from '@kit.ArkUI';
import type { common } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { appLog } from './AppLog';

// Simulated Picture-in-Picture keepalive.
//
// HarmonyOS does not let a normal app run a resident daemon: the VPN extension
// and the continuous task live in the app process, and swiping the main window
// away lets the system reclaim both. A PiP window is owned by the system window
// manager and survives the main task being swiped away, so the UIAbility (and
// with it the continuous task and the 5 s heartbeat supervisor) stays alive.
// This is the "模拟画中画" method used by ClashBox/Bettbox, not a desktop widget.
//
// Flow: while the tunnel is running, onPageHide enables auto-start; the system
// pops a small PiP window when the app goes to the background. onPageShow
// stops it again. The PiP content is a static "way / 保活中" card.

class PipParams {
  text: string = '保活中';
}

@Builder
function PipCardBuilder(params: PipParams) {
  Column({ space: 2 }) {
    Text('way')
      .fontSize(16)
      .fontWeight(FontWeight.Bold)
      .fontColor('#E8F1FF')
    Text(params.text)
      .fontSize(9)
      .fontColor('#7C8FA9')
      .maxLines(1)
  }
  .width('100%')
  .height('100%')
  .justifyContent(FlexAlign.Center)
  .backgroundColor('#0B1020')
}

class PipNodeController extends NodeController {
  private node: BuilderNode<[PipParams]> | null = null;
  private builder: WrappedBuilder<[PipParams]> = wrapBuilder(PipCardBuilder);

  makeNode(uiContext: UIContext): FrameNode {
    if (this.node === null) {
      const params: PipParams = new PipParams();
      params.text = '保活中';
      const node = new BuilderNode<[PipParams]>(uiContext);
      node.build(this.builder, params);
      this.node = node;
    }
    return this.node.getFrameNode()!;
  }
}

export class PipManager {
  private static instance: PipManager = new PipManager();
  private controller: PiPWindow.PiPController | null = null;
  private componentController: XComponentController = new XComponentController();
  private xComponent: typeNode.XComponent | null = null;
  private autoStartWanted: boolean = false;

  static getInstance(): PipManager {
    return PipManager.instance;
  }

  // Must run on the main window's UIContext, once. EntryAbility calls this in
  // onWindowStageCreate after loadContent.
  makeTypeNode(ctx: UIContext): void {
    if (this.xComponent !== null) {
      return;
    }
    try {
      this.xComponent = typeNode.createNode(ctx, 'XComponent', {
        type: XComponentType.SURFACE,
        controller: this.componentController
      });
    } catch (error) {
      // No context is available on this path; the caller logs PiP failures.
    }
  }

  private init(context: common.UIAbilityContext): void {
    if (this.controller !== null) {
      return;
    }
    if (!PiPWindow.isPiPEnabled()) {
      appLog(context, 'pip', 'PiP is not enabled on this device');
      return;
    }
    if (this.xComponent === null) {
      appLog(context, 'pip', 'PiP typeNode is not ready');
      return;
    }
    const config: PiPWindow.PiPConfiguration = {
      context: context,
      componentController: this.componentController,
      templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
      contentWidth: 160,
      contentHeight: 90,
      customUIController: new PipNodeController()
    };
    PiPWindow.create(config, this.xComponent).then((controller: PiPWindow.PiPController) => {
      this.controller = controller;
      // The controller is created lazily; apply the latest auto-start request.
      controller.setAutoStartEnabled(this.autoStartWanted);
      controller.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
        appLog(context, 'pip', 'state=' + state + ' reason=' + reason);
      });
      appLog(context, 'pip', 'controller ready, autoStart=' + this.autoStartWanted);
    }).catch((error: BusinessError) => {
      appLog(context, 'pip', 'create failed: ' + (error.message ?? 'unknown'));
    });
  }

  // Creates the controller without enabling auto-start. Called once the
  // typeNode exists, so the page can later flip auto-start cheaply.
  prepare(context: common.UIAbilityContext): void {
    this.init(context);
  }

  setAutoStart(context: common.UIAbilityContext, enabled: boolean): void {
    this.autoStartWanted = enabled;
    if (enabled) {
      this.init(context);
    }
    if (this.controller !== null) {
      this.controller.setAutoStartEnabled(enabled);
    }
  }

  stop(): void {
    if (this.controller === null) {
      return;
    }
    this.controller.stopPiP().catch((error: BusinessError) => {
    });
  }
}
