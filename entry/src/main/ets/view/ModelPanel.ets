import { SceneObject } from '../model/SceneModel';

// Modelling sidebar: add primitives, pick one from the list, move / rotate / scale it, duplicate,
// array, centre, delete, and combine two objects with a boolean operation.
@Component
export struct ModelPanel {
  @Link scene: SceneObject[];
  @Link selectedIndex: number;
  //! Bumped by the page after every edit so this panel re-renders (array item fields are not
  //! observed through @Link alone).
  @Prop version: number;
  onSceneChanged?: () => void;
  onBoolean?: (operation: string) => void;
  onUndo?: () => void;
  onRedo?: () => void;
  onSaveProject?: () => void;
  onOpenProject?: () => void;
  onExportStl?: () => void;
  onExport3mf?: () => void;

  @State arrayCount: number = 3;

  private addPrimitive(kind: string, label: string): void {
    const object = new SceneObject(kind, `${label} ${this.scene.length + 1}`, 20);
    object.px = 0;
    this.scene.push(object);
    this.selectedIndex = this.scene.length - 1;
    this.notify();
  }

  private duplicateSelected(): void {
    if (this.selectedIndex < 0 || this.selectedIndex >= this.scene.length) {
      return;
    }
    const copy = this.scene[this.selectedIndex].clone();
    copy.label = `${copy.label} 副本`;
    copy.px = copy.px + 30;
    this.scene.push(copy);
    this.selectedIndex = this.scene.length - 1;
    this.notify();
  }

  //! Copies the selected object `arrayCount` times along X, 30 mm apart.
  private arraySelected(): void {
    if (this.selectedIndex < 0 || this.selectedIndex >= this.scene.length) {
      return;
    }
    const source = this.scene[this.selectedIndex];
    for (let i = 1; i < this.arrayCount; i++) {
      const copy = source.clone();
      copy.label = `${source.label} #${i + 1}`;
      copy.px = source.px + 30 * i;
      this.scene.push(copy);
    }
    this.notify();
  }

  private deleteSelected(): void {
    if (this.selectedIndex < 0 || this.selectedIndex >= this.scene.length) {
      return;
    }
    this.scene.splice(this.selectedIndex, 1);
    if (this.selectedIndex >= this.scene.length) {
      this.selectedIndex = this.scene.length - 1;
    }
    this.notify();
  }

  private notify(): void {
    this.onSceneChanged?.();
  }

  private selected(): SceneObject | undefined {
    if (this.selectedIndex < 0 || this.selectedIndex >= this.scene.length) {
      return undefined;
    }
    return this.scene[this.selectedIndex];
  }

  @Builder
  numberRow(label: string, value: string, minus: () => void, plus: () => void) {
    Row({ space: 6 }) {
      Text(label)
        .fontSize(12)
        .fontColor('#c8ccd4')
        .width(52)
      Button('-')
        .fontSize(14)
        .width(26)
        .height(26)
        .padding(0)
        .backgroundColor('#2a2d33')
        .onClick(minus)
      Text(value)
        .fontSize(12)
        .fontColor('#e6e8ec')
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
      Button('+')
        .fontSize(14)
        .width(26)
        .height(26)
        .padding(0)
        .backgroundColor('#2a2d33')
        .onClick(plus)
    }
    .width('100%')
    .height(32)
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text('建模')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#ffffff')
          .layoutWeight(1)
        Button('撤销')
          .fontSize(11)
          .height(26)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.onUndo?.();
          })
        Button('重做')
          .fontSize(11)
          .height(26)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.onRedo?.();
          })
      }
      .width('100%')

      Row({ space: 6 }) {
        Button('立方体')
          .fontSize(11)
          .height(28)
          .layoutWeight(1)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.addPrimitive('cube', '立方体');
          })
        Button('圆柱')
          .fontSize(11)
          .height(28)
          .layoutWeight(1)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.addPrimitive('cylinder', '圆柱');
          })
        Button('球')
          .fontSize(11)
          .height(28)
          .layoutWeight(1)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.addPrimitive('sphere', '球');
          })
        Button('圆锥')
          .fontSize(11)
          .height(28)
          .layoutWeight(1)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.addPrimitive('cone', '圆锥');
          })
      }
      .width('100%')

      List({ space: 4 }) {
        ForEach(this.scene, (item: SceneObject, index: number) => {
          ListItem() {
            Row() {
              Text(item.label)
                .fontSize(12)
                .fontColor(index === this.selectedIndex ? '#ffffff' : '#c8ccd4')
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .height(30)
            .padding({ left: 8, right: 8 })
            .backgroundColor(index === this.selectedIndex ? '#2f6fd0' : '#1c1f24')
            .borderRadius(6)
            .onClick(() => {
              this.selectedIndex = index;
              this.version = this.version;
            })
          }
        }, (item: SceneObject, index: number): string => `${index}-${item.label}`)
      }
      .width('100%')
      .height(this.scene.length > 3 ? 108 : 36 * this.scene.length)
      .scrollBar(BarState.Auto)

      if (this.selected() !== undefined) {
        // Exact size for primitives (the imported/boolean meshes carry their own geometry).
        if (this.selected()!.kind !== 'imported' && this.selected()!.kind !== 'mesh') {
          Row({ space: 6 }) {
            Text('尺寸mm')
              .fontSize(12)
              .fontColor('#c8ccd4')
              .width(52)
            TextInput({ text: this.selected()!.size.toFixed(1) })
              .type(InputType.NUMBER_DECIMAL)
              .fontSize(12)
              .height(28)
              .layoutWeight(1)
              .backgroundColor('#1c1f24')
              .fontColor('#e6e8ec')
              .textAlign(TextAlign.Center)
              .onChange((value: string) => {
                this.selected()!.setSize(Number.parseFloat(value));
                this.notify();
              })
          }
          .width('100%')
          .height(32)
        }

        this.numberRow('位置 X', this.selected()!.px.toFixed(0), () => {
          this.selected()!.adjustPosition(0, -5);
          this.notify();
        }, () => {
          this.selected()!.adjustPosition(0, 5);
          this.notify();
        })
        this.numberRow('位置 Y', this.selected()!.py.toFixed(0), () => {
          this.selected()!.adjustPosition(1, -5);
          this.notify();
        }, () => {
          this.selected()!.adjustPosition(1, 5);
          this.notify();
        })
        this.numberRow('高度 Z', this.selected()!.pz.toFixed(0), () => {
          this.selected()!.adjustPosition(2, -5);
          this.notify();
        }, () => {
          this.selected()!.adjustPosition(2, 5);
          this.notify();
        })
        this.numberRow('旋转 X', `${this.selected()!.rx.toFixed(0)}°`, () => {
          this.selected()!.adjustRotation(0, -15);
          this.notify();
        }, () => {
          this.selected()!.adjustRotation(0, 15);
          this.notify();
        })
        this.numberRow('旋转 Y', `${this.selected()!.ry.toFixed(0)}°`, () => {
          this.selected()!.adjustRotation(1, -15);
          this.notify();
        }, () => {
          this.selected()!.adjustRotation(1, 15);
          this.notify();
        })
        this.numberRow('旋转 Z', `${this.selected()!.rz.toFixed(0)}°`, () => {
          this.selected()!.adjustRotation(2, -15);
          this.notify();
        }, () => {
          this.selected()!.adjustRotation(2, 15);
          this.notify();
        })
        this.numberRow('缩放', `${this.selected()!.scale.toFixed(2)}x`, () => {
          this.selected()!.adjustScale(-0.1);
          this.notify();
        }, () => {
          this.selected()!.adjustScale(0.1);
          this.notify();
        })

        Row({ space: 6 }) {
          Button('复制')
            .fontSize(11)
            .height(28)
            .layoutWeight(1)
            .backgroundColor('#2a2d33')
            .onClick(() => {
              this.duplicateSelected();
            })
          Button('居中')
            .fontSize(11)
            .height(28)
            .layoutWeight(1)
            .backgroundColor('#2a2d33')
            .onClick(() => {
              this.selected()!.centerOnPlate();
              this.notify();
            })
          Button('删除')
            .fontSize(11)
            .height(28)
            .layoutWeight(1)
            .backgroundColor('#5a2a2a')
            .onClick(() => {
              this.deleteSelected();
            })
        }
        .width('100%')

        // Array along X.
        Row({ space: 6 }) {
          Text('阵列个数')
            .fontSize(12)
            .fontColor('#c8ccd4')
            .layoutWeight(1)
          Button('-')
            .fontSize(14)
            .width(26)
            .height(26)
            .padding(0)
            .backgroundColor('#2a2d33')
            .onClick(() => {
              this.arrayCount = Math.max(2, this.arrayCount - 1);
            })
          Text(`${this.arrayCount}`)
            .fontSize(12)
            .fontColor('#e6e8ec')
            .width(28)
            .textAlign(TextAlign.Center)
          Button('+')
            .fontSize(14)
            .width(26)
            .height(26)
            .padding(0)
            .backgroundColor('#2a2d33')
            .onClick(() => {
              this.arrayCount = Math.min(20, this.arrayCount + 1);
            })
          Button('阵列')
            .fontSize(11)
            .height(26)
            .backgroundColor('#2f6fd0')
            .onClick(() => {
              this.arraySelected();
            })
        }
        .width('100%')
        .height(30)

        // Boolean with the object ABOVE the selected one: A = previous, B = selected.
        Row({ space: 6 }) {
          Text('布尔(与上一个)')
            .fontSize(11)
            .fontColor(this.selectedIndex === 0 ? '#5d636d' : '#9099a6')
            .layoutWeight(1)
          Button('并')
            .fontSize(11)
            .height(26)
            .enabled(this.scene.length > 1)
            .backgroundColor('#2a2d33')
            .onClick(() => {
              this.onBoolean?.('union');
            })
          Button('差')
            .fontSize(11)
            .height(26)
            .enabled(this.scene.length > 1)
            .backgroundColor('#2a2d33')
            .onClick(() => {
              this.onBoolean?.('subtract');
            })
          Button('交')
            .fontSize(11)
            .height(26)
            .enabled(this.scene.length > 1)
            .backgroundColor('#2a2d33')
            .onClick(() => {
              this.onBoolean?.('intersect');
            })
        }
        .width('100%')
        .height(28)
      }
      // Project handling and export.
      Row({ space: 6 }) {
        Button('保存工程')
          .fontSize(10)
          .height(26)
          .layoutWeight(1)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.onSaveProject?.();
          })
        Button('打开工程')
          .fontSize(10)
          .height(26)
          .layoutWeight(1)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.onOpenProject?.();
          })
      }
      .width('100%')

      Row({ space: 6 }) {
        Button('导出 STL')
          .fontSize(10)
          .height(26)
          .layoutWeight(1)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.onExportStl?.();
          })
        Button('导出 3MF')
          .fontSize(10)
          .height(26)
          .layoutWeight(1)
          .backgroundColor('#2a2d33')
          .onClick(() => {
            this.onExport3mf?.();
          })
      }
      .width('100%')

      Divider().color('#2a2d33')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ bottom: 12 })
  }
}
