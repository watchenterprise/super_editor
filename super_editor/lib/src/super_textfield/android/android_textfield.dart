import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/src/infrastructure/attributed_text_styles.dart';
import 'package:super_editor/src/infrastructure/flutter/flutter_pipeline.dart';
import 'package:super_editor/src/infrastructure/focus.dart';
import 'package:super_editor/src/infrastructure/ime_input_owner.dart';
import 'package:super_editor/src/infrastructure/platforms/android/toolbar.dart';
import 'package:super_editor/src/infrastructure/touch_controls.dart';
import 'package:super_editor/src/super_textfield/android/_editing_controls.dart';
import 'package:super_editor/src/super_textfield/android/_user_interaction.dart';
import 'package:super_editor/src/super_textfield/infrastructure/fill_width_if_constrained.dart';
import 'package:super_editor/src/super_textfield/infrastructure/hint_text.dart';
import 'package:super_editor/src/super_textfield/infrastructure/text_scrollview.dart';
import 'package:super_editor/src/super_textfield/input_method_engine/_ime_text_editing_controller.dart';
import 'package:super_text_layout/super_text_layout.dart';

import '../../infrastructure/_logging.dart';
import '../metrics.dart';
import '../styles.dart';

export '_caret.dart';

final _log = androidTextFieldLog;

class SuperAndroidTextField extends StatefulWidget {
  const SuperAndroidTextField({
    Key? key,
    this.focusNode,
    this.tapRegionGroupId,
    this.textController,
    this.textAlign = TextAlign.left,
    this.textStyleBuilder = defaultTextFieldStyleBuilder,
    this.hintBehavior = HintBehavior.displayHintUntilFocus,
    this.hintBuilder,
    this.minLines,
    this.maxLines = 1,
    this.lineHeight,
    required this.caretStyle,
    this.blinkTimingMode = BlinkTimingMode.ticker,
    required this.selectionColor,
    required this.handlesColor,
    this.textInputAction,
    this.imeConfiguration,
    this.popoverToolbarBuilder = _defaultAndroidToolbarBuilder,
    this.showDebugPaint = false,
    this.padding,
  }) : super(key: key);

  /// [FocusNode] attached to this text field.
  final FocusNode? focusNode;

  /// {@macro super_text_field_tap_region_group_id}
  final String? tapRegionGroupId;

  /// Controller that owns the text content and text selection for
  /// this text field.
  final ImeAttributedTextEditingController? textController;

  /// The alignment to use for text in this text field.
  final TextAlign textAlign;

  /// Text style factory that creates styles for the content in
  /// [textController] based on the attributions in that content.
  final AttributionStyleBuilder textStyleBuilder;

  /// Policy for when the hint should be displayed.
  final HintBehavior hintBehavior;

  /// Builder that creates the hint widget, when a hint is displayed.
  ///
  /// To easily build a hint with styled text, see [StyledHintBuilder].
  final WidgetBuilder? hintBuilder;

  /// The visual representation of the caret.
  final CaretStyle caretStyle;

  /// The timing mechanism used to blink, e.g., `Ticker` or `Timer`.
  ///
  /// `Timer`s are not expected to work in tests.
  final BlinkTimingMode blinkTimingMode;

  /// Color of the selection rectangle for selected text.
  final Color selectionColor;

  /// Color of the selection handles.
  final Color handlesColor;

  /// The minimum height of this text field, represented as a
  /// line count.
  ///
  /// If [minLines] is non-null and greater than `1`, [lineHeight]
  /// must also be provided because there is no guarantee that all
  /// lines of text have the same height.
  ///
  /// See also:
  ///
  ///  * [maxLines]
  ///  * [lineHeight]
  final int? minLines;

  /// The maximum height of this text field, represented as a
  /// line count.
  ///
  /// If text exceeds the maximum line height, scrolling dynamics
  /// are added to accommodate the overflowing text.
  ///
  /// If [maxLines] is non-null and greater than `1`, [lineHeight]
  /// must also be provided because there is no guarantee that all
  /// lines of text have the same height.
  ///
  /// See also:
  ///
  ///  * [minLines]
  ///  * [lineHeight]
  final int? maxLines;

  /// The height of a single line of text in this text scroll view, used
  /// with [minLines] and [maxLines] to size the text field.
  ///
  /// If a [lineHeight] is provided, the text field viewport is sized as a
  /// multiple of that [lineHeight]. If no [lineHeight] is provided, the
  /// text field viewport is sized as a multiple of the line-height of the
  /// first line of text.
  final double? lineHeight;

  /// The type of action associated with the action button on the mobile
  /// keyboard.
  ///
  /// This property is ignored when an [imeConfiguration] is provided.
  @Deprecated('This will be removed in a future release. Use imeConfiguration instead')
  final TextInputAction? textInputAction;

  /// Preferences for how the platform IME should look and behave during editing.
  final TextInputConfiguration? imeConfiguration;

  /// Whether to paint debug guides.
  final bool showDebugPaint;

  /// Builder that creates the popover toolbar widget that appears when text is selected.
  final Widget Function(BuildContext, AndroidEditingOverlayController, ToolbarConfig) popoverToolbarBuilder;

  /// Padding placed around the text content of this text field, but within the
  /// scrollable viewport.
  final EdgeInsets? padding;

  @override
  State createState() => SuperAndroidTextFieldState();
}

class SuperAndroidTextFieldState extends State<SuperAndroidTextField>
    with TickerProviderStateMixin, WidgetsBindingObserver
    implements ProseTextBlock, ImeInputOwner {
  static const Duration _autoScrollAnimationDuration = Duration(milliseconds: 100);
  static const Curve _autoScrollAnimationCurve = Curves.fastOutSlowIn;

  final _textFieldKey = GlobalKey();
  final _textFieldLayerLink = LayerLink();
  final _textContentLayerLink = LayerLink();
  final _scrollKey = GlobalKey<AndroidTextFieldTouchInteractorState>();
  final _textContentKey = GlobalKey<ProseTextState>();

  late FocusNode _focusNode;

  late ImeAttributedTextEditingController _textEditingController;

  final _magnifierLayerLink = LayerLink();
  late AndroidEditingOverlayController _editingOverlayController;

  late TextScrollController _textScrollController;

  // OverlayEntry that displays the toolbar and magnifier, and
  // positions the invisible touch targets for base/extent
  // dragging.
  OverlayEntry? _controlsOverlayEntry;

  @override
  void initState() {
    super.initState();
    _focusNode = (widget.focusNode ?? FocusNode())..addListener(_updateSelectionAndImeConnectionOnFocusChange);

    _textEditingController = (widget.textController ?? ImeAttributedTextEditingController())
      ..addListener(_onTextOrSelectionChange)
      ..onPerformActionPressed ??= _onPerformActionPressed;

    _textScrollController = TextScrollController(
      textController: _textEditingController,
      tickerProvider: this,
    )..addListener(_onTextScrollChange);

    _editingOverlayController = AndroidEditingOverlayController(
      textController: _textEditingController,
      magnifierFocalPoint: _magnifierLayerLink,
    );

    WidgetsBinding.instance.addObserver(this);

    if (_focusNode.hasFocus) {
      // The given FocusNode already has focus, we need to update selection and attach to IME.
      onNextFrame((_) => _updateSelectionAndImeConnectionOnFocusChange());
    }
  }

  @override
  void didUpdateWidget(SuperAndroidTextField oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      _focusNode.removeListener(_updateSelectionAndImeConnectionOnFocusChange);
      _focusNode = (widget.focusNode ?? FocusNode())..addListener(_updateSelectionAndImeConnectionOnFocusChange);
    }

    if (widget.textInputAction != oldWidget.textInputAction &&
        widget.textInputAction != null &&
        _textEditingController.isAttachedToIme) {
      _textEditingController.updateTextInputConfiguration(
        textInputAction: widget.textInputAction!,
        textInputType: _isMultiline ? TextInputType.multiline : TextInputType.text,
      );
    }

    if (widget.imeConfiguration != oldWidget.imeConfiguration &&
        widget.imeConfiguration != null &&
        _textEditingController.isAttachedToIme) {
      _textEditingController.updateTextInputConfiguration(
        textInputAction: widget.imeConfiguration!.inputAction,
        textInputType: widget.imeConfiguration!.inputType,
        autocorrect: widget.imeConfiguration!.autocorrect,
        enableSuggestions: widget.imeConfiguration!.enableSuggestions,
        keyboardAppearance: widget.imeConfiguration!.keyboardAppearance,
      );
    }

    if (widget.textController != oldWidget.textController) {
      _textEditingController.removeListener(_onTextOrSelectionChange);
      if (_textEditingController.onPerformActionPressed == _onPerformActionPressed) {
        _textEditingController.onPerformActionPressed = null;
      }
      if (widget.textController != null) {
        _textEditingController = widget.textController!;
      } else {
        _textEditingController = ImeAttributedTextEditingController();
      }
      _textEditingController
        ..addListener(_onTextOrSelectionChange)
        ..onPerformActionPressed ??= _onPerformActionPressed;
    }

    if (widget.showDebugPaint != oldWidget.showDebugPaint) {
      onNextFrame((_) => _rebuildEditingOverlayControls());
    }
  }

  @override
  void reassemble() {
    super.reassemble();

    // On Hot Reload we need to remove any visible overlay controls and then
    // bring them back a frame later to avoid having the controls attempt
    // to access the layout of the text. The text layout is not immediately
    // available upon Hot Reload. Accessing it results in an exception.
    _removeEditingOverlayControls();

    onNextFrame((_) => _showEditingControlsOverlay());
  }

  @override
  void dispose() {
    _removeEditingOverlayControls();

    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      // Dispose after the current frame so that other widgets have
      // time to remove their listeners.
      _editingOverlayController.dispose();
    });

    _textEditingController
      ..removeListener(_onTextOrSelectionChange)
      ..detachFromIme();
    if (widget.textController == null) {
      WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
        // Dispose after the current frame so that other widgets have
        // time to remove their listeners.
        _textEditingController.dispose();
      });
    }

    _focusNode.removeListener(_updateSelectionAndImeConnectionOnFocusChange);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }

    _textScrollController
      ..removeListener(_onTextScrollChange)
      ..dispose();

    WidgetsBinding.instance.removeObserver(this);

    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // The available screen dimensions may have changed, e.g., due to keyboard
    // appearance/disappearance.
    onNextFrame((_) {
      if (!_focusNode.hasFocus) {
        return;
      }

      _autoScrollToKeepTextFieldVisible();
    });
  }

  @override
  ProseTextLayout get textLayout => _textContentKey.currentState!.textLayout;

  @override
  DeltaTextInputClient get imeClient => _textEditingController;

  bool get _isMultiline => (widget.minLines ?? 1) != 1 || widget.maxLines != 1;

  void _updateSelectionAndImeConnectionOnFocusChange() {
    if (_focusNode.hasFocus) {
      if (!_textEditingController.isAttachedToIme) {
        _log.info('Attaching TextInputClient to TextInput');
        setState(() {
          if (!_textEditingController.selection.isValid) {
            _textEditingController.selection = TextSelection.collapsed(offset: _textEditingController.text.text.length);
          }

          if (widget.imeConfiguration != null) {
            _textEditingController.attachToImeWithConfig(widget.imeConfiguration!);
          } else {
            _textEditingController.attachToIme(
              textInputAction: widget.textInputAction ?? TextInputAction.done,
              textInputType: _isMultiline ? TextInputType.multiline : TextInputType.text,
            );
          }

          _autoScrollToKeepTextFieldVisible();
          _showEditingControlsOverlay();
        });
      }
    } else {
      _log.info('Lost focus. Detaching TextInputClient from TextInput.');
      setState(() {
        _textEditingController.detachFromIme();
        _textEditingController.selection = const TextSelection.collapsed(offset: -1);
        _removeEditingOverlayControls();
      });
    }
  }

  void _onTextOrSelectionChange() {
    if (_textEditingController.selection.isCollapsed) {
      _editingOverlayController.hideToolbar();
    }
    _textScrollController.ensureExtentIsVisible();
  }

  void _onTextScrollChange() {
    if (_controlsOverlayEntry != null) {
      _rebuildEditingOverlayControls();
    }
  }

  /// Displays [AndroidEditingOverlayControls] in the app's [Overlay], if not already
  /// displayed.
  void _showEditingControlsOverlay() {
    if (_controlsOverlayEntry == null) {
      _controlsOverlayEntry = OverlayEntry(builder: (overlayContext) {
        return AndroidEditingOverlayControls(
          editingController: _editingOverlayController,
          textScrollController: _textScrollController,
          textFieldLayerLink: _textFieldLayerLink,
          textFieldKey: _textFieldKey,
          textContentLayerLink: _textContentLayerLink,
          textContentKey: _textContentKey,
          tapRegionGroupId: widget.tapRegionGroupId,
          handleColor: widget.handlesColor,
          popoverToolbarBuilder: widget.popoverToolbarBuilder,
          showDebugPaint: widget.showDebugPaint,
        );
      });

      Overlay.of(context).insert(_controlsOverlayEntry!);
    }
  }

  /// Rebuilds the [AndroidEditingControls] in the app's [Overlay], if
  /// they're currently displayed.
  void _rebuildEditingOverlayControls() {
    _controlsOverlayEntry?.markNeedsBuild();
  }

  /// Removes [AndroidEditingControls] from the app's [Overlay], if they're
  /// currently displayed.
  void _removeEditingOverlayControls() {
    if (_controlsOverlayEntry != null) {
      _controlsOverlayEntry!.remove();
      _controlsOverlayEntry = null;
    }
  }

  /// Handles actions from the IME
  void _onPerformActionPressed(TextInputAction action) {
    switch (action) {
      case TextInputAction.done:
        _focusNode.unfocus();
        break;
      case TextInputAction.next:
        _focusNode.nextFocus();
        break;
      case TextInputAction.previous:
        _focusNode.previousFocus();
        break;
      default:
        _log.warning("User pressed unhandled action button: $action");
    }
  }

  /// Handles key presses
  ///
  /// Some third party keyboards report backspace as a key press
  /// rather than a deletion delta, so we need to handle them manually
  KeyEventResult _onKeyPressed(FocusNode focusNode, RawKeyEvent keyEvent) {
    _log.finer('_onKeyPressed - keyEvent: ${keyEvent.character}');
    if (keyEvent is! RawKeyDownEvent) {
      _log.finer('_onKeyPressed - not a "down" event. Ignoring.');
      return KeyEventResult.ignored;
    }
    if (keyEvent.logicalKey != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }

    if (_textEditingController.selection.isCollapsed) {
      _textEditingController.deletePreviousCharacter();
    } else {
      _textEditingController.deleteSelection();
    }

    return KeyEventResult.handled;
  }

  /// Scrolls the ancestor [Scrollable], if any, so [SuperTextField]
  /// is visible on the viewport when it's focused
  void _autoScrollToKeepTextFieldVisible() {
    // If we are not inside a [Scrollable] we don't autoscroll
    final ancestorScrollable = _findAncestorScrollable(context);
    if (ancestorScrollable == null) {
      return;
    }

    // Compute the text field offset that should be visible to the user
    final textFieldFocalPoint = widget.maxLines == null && _textEditingController.selection.isValid
        ? _textContentKey.currentState!.textLayout.getOffsetAtPosition(
            TextPosition(offset: _textEditingController.selection.extentOffset),
          )
        : Offset.zero;

    final lineHeight = _textContentKey.currentState!.textLayout.getLineHeightAtPosition(
      TextPosition(offset: _textEditingController.selection.extentOffset),
    );
    final fieldBox = context.findRenderObject() as RenderBox;

    // The area of the text field that should be revealed.
    // We add a small margin to leave some space between the text field and the keyboard.
    final textFieldFocalRect = Rect.fromLTWH(
      textFieldFocalPoint.dx,
      textFieldFocalPoint.dy,
      fieldBox.size.width,
      lineHeight + gapBetweenCaretAndKeyboard,
    );

    fieldBox.showOnScreen(
      rect: textFieldFocalRect,
      duration: _autoScrollAnimationDuration,
      curve: _autoScrollAnimationCurve,
    );
  }

  ScrollableState? _findAncestorScrollable(BuildContext context) {
    final ancestorScrollable = Scrollable.maybeOf(context);
    if (ancestorScrollable == null) {
      return null;
    }

    final direction = ancestorScrollable.axisDirection;
    // If the direction is horizontal, then we are inside a widget like a TabBar
    // or a horizontal ListView, so we can't use the ancestor scrollable
    if (direction == AxisDirection.left || direction == AxisDirection.right) {
      return null;
    }

    return ancestorScrollable;
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      groupId: widget.tapRegionGroupId,
      child: NonReparentingFocus(
        key: _textFieldKey,
        focusNode: _focusNode,
        onKey: _onKeyPressed,
        child: CompositedTransformTarget(
          link: _textFieldLayerLink,
          child: AndroidTextFieldTouchInteractor(
            focusNode: _focusNode,
            textKey: _textContentKey,
            textFieldLayerLink: _textFieldLayerLink,
            textController: _textEditingController,
            editingOverlayController: _editingOverlayController,
            textScrollController: _textScrollController,
            isMultiline: _isMultiline,
            handleColor: widget.handlesColor,
            showDebugPaint: widget.showDebugPaint,
            child: TextScrollView(
              key: _scrollKey,
              textScrollController: _textScrollController,
              textKey: _textContentKey,
              textEditingController: _textEditingController,
              textAlign: widget.textAlign,
              minLines: widget.minLines,
              maxLines: widget.maxLines,
              lineHeight: widget.lineHeight,
              perLineAutoScrollDuration: const Duration(milliseconds: 100),
              showDebugPaint: widget.showDebugPaint,
              padding: widget.padding,
              child: ListenableBuilder(
                listenable: _textEditingController,
                builder: (context, _) {
                  final isTextEmpty = _textEditingController.text.text.isEmpty;
                  final showHint = widget.hintBuilder != null &&
                      ((isTextEmpty && widget.hintBehavior == HintBehavior.displayHintUntilTextEntered) ||
                          (isTextEmpty &&
                              !_focusNode.hasFocus &&
                              widget.hintBehavior == HintBehavior.displayHintUntilFocus));

                  return CompositedTransformTarget(
                    link: _textContentLayerLink,
                    child: Stack(
                      children: [
                        if (showHint) widget.hintBuilder!(context),
                        _buildSelectableText(),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSelectableText() {
    final textSpan = _textEditingController.text.text.isNotEmpty
        ? _textEditingController.text.computeTextSpan(widget.textStyleBuilder)
        : TextSpan(text: "", style: widget.textStyleBuilder({}));

    return FillWidthIfConstrained(
      child: SuperTextWithSelection.single(
        key: _textContentKey,
        richText: textSpan,
        textAlign: widget.textAlign,
        textScaler: MediaQuery.textScalerOf(context),
        userSelection: UserSelection(
          highlightStyle: SelectionHighlightStyle(
            color: widget.selectionColor,
          ),
          caretStyle: widget.caretStyle,
          selection: _textEditingController.selection,
          hasCaret: _focusNode.hasFocus,
          blinkTimingMode: widget.blinkTimingMode,
        ),
      ),
    );
  }
}

Widget _defaultAndroidToolbarBuilder(
  BuildContext context,
  AndroidEditingOverlayController controller,
  ToolbarConfig config,
) {
  return AndroidTextEditingFloatingToolbar(
    onCutPressed: () {
      final textController = controller.textController;

      final selection = textController.selection;
      if (selection.isCollapsed) {
        return;
      }

      final selectedText = selection.textInside(textController.text.text);

      textController.deleteSelectedText();

      Clipboard.setData(ClipboardData(text: selectedText));
    },
    onCopyPressed: () {
      final textController = controller.textController;
      final selection = textController.selection;
      final selectedText = selection.textInside(textController.text.text);

      Clipboard.setData(ClipboardData(text: selectedText));
    },
    onPastePressed: () async {
      final clipboardContent = await Clipboard.getData('text/plain');
      if (clipboardContent == null || clipboardContent.text == null) {
        return;
      }

      final textController = controller.textController;
      final selection = textController.selection;
      if (selection.isCollapsed) {
        textController.insertAtCaret(text: clipboardContent.text!);
      } else {
        textController.replaceSelectionWithUnstyledText(replacementText: clipboardContent.text!);
      }
    },
    onSelectAllPressed: () {
      controller.textController.selectAll();
    },
  );
}
