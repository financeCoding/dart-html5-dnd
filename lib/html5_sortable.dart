/**
 * Helper library for reordering of HTML elements with native HTML5 Drag and
 * Drop.
 */
library html5_sortable;

import 'dart:html';
import 'dart:async';
import 'package:meta/meta.dart';
import 'package:logging/logging.dart';
import 'package:html5_dnd/html5_dnd.dart';

import 'package:html5_dnd/src/css_utils.dart' as css;
import 'package:html5_dnd/src/html5_utils.dart' as html5;

final _logger = new Logger("html5_sortable");

/**
 * Drag and Drop for reordering elements.
 */
class Sortable {
  /// Keep track of sortable elements.
  List<Element> sortableElements;

  // -------------------
  // Options
  // -------------------
  /**
   * CSS class set on the placeholder element. Default is 'dnd-placeholder'. If 
   * null, no css class is added.
   */
  String placeholderClass = 'dnd-placeholder';
  
  /**
   * If true, forces the placeholder to have the computed size of the dragged
   * element. Default is true.
   * 
   * **Note:** Placeholders should have at least the size of the dragged 
   * element. If smaller, the mouse might already be outside of the placeholder 
   * when the drag is started. This leads to a bad user experience.
   */
  bool forcePlaceholderSize = true;
  
  // -------------------
  // Events
  // -------------------
  /**
   * Returns the stream of completed sortable drag-and-drop events.
   * If the user aborted the drag, no event is fired.
   */
  Stream<SortableResult> get onSortableComplete => _onSortableComplete.stream;
  
  
  // -------------------
  // Private
  // -------------------
  /// The placeholder for the draggable element.
  _Placeholder _placeholder;
  
  /// Position of the draggable element before dragging.
  Position _originalPosition;
  
  /// Indicates (for the onDragEnd event) if the draggable has been dropped.
  /// If false, no real drop on a dropzone element has happened, i.e. the user 
  /// aborted the drag.
  bool _dropped = false;
  
  /// Must be set to true for sortable grids. This ensures that different sized
  /// items in grids are handled correctly.
  bool _isGrid = false;
  
  /// Callback function that is called when the drag is ended by a drop.
  /// If the user aborted the drag, the function is not called.
  StreamController<SortableResult> _onSortableComplete = 
      new StreamController<SortableResult>(sync: true);
  
  static final RegExp _floatRegExp = new RegExp(r'left|right');
  
  /**
   * Cunstructs and initializes sortable drag and drop for the specified 
   * [sortableElements]. 
   * 
   * If [handle] is set to a value other than null, the drag is restricted to 
   * the specified subelement of [element].
   */
  Sortable(this.sortableElements, {String handle: null}) {
    // Sortable elements are at the same time draggables and dropzones
    for (Element sortableElement in sortableElements) {
      // Test if it might be a grid with floats.
      if (!_isGrid 
          && _floatRegExp.hasMatch(sortableElement.getComputedStyle().float)) {
        _logger.finest('floating element detected --> handle as grid');
        _isGrid = true;
      }
      
      _installDraggable(sortableElement, handle);
      // Create dropzones with all sortableElements as acceptDraggables.
      _installDropzone(sortableElement, sortableElements);
    }
  }
  
  /**
   * Installs drag events for the [sortableElement].
   */
  void _installDraggable(Element sortableElement, String handle) {
   new Draggable(sortableElement, handle: handle)
    ..dropEffect = 'move'
    
    ..onDragStart.listen((DraggableEvent event) {
      _logger.finest('onDragStart');
      
      _originalPosition = new Position(currentDraggable.element.parent,
          html5.getElementIndexInParent(currentDraggable.element));
      _placeholder = new _Placeholder(event.draggable.element, placeholderClass, 
          forcePlaceholderSize);
      _placeholder.onDrop.listen((_) {
        _dropped = true;
        _showDraggable(_placeholder.placeholderPosition);
      });
    })
    
    ..onDragEnd.listen((DraggableEvent event) {
      _logger.finest('onDragEnd');
      if (!_dropped) {
        // Not dropped. This means the drag ended outside of a placeholder or
        // the drag was cancelled somehow (ESC-key, ...)
        // Revert to state before dragging.
        _logger.finest('onDragEnd not dropped -> Revert to state before dragging');
        _showDraggable(_originalPosition);
      }
      
      // Reset variables.
      _originalPosition = null;
      _placeholder = null;
      _dropped = false;
    });
  }
  
  /**
   * Installs dropzone events for the [sortableElement].
   */
  void _installDropzone(Element sortableElement, 
                           List<Element> acceptDraggables) {
    Dropzone dropzone = new Dropzone(sortableElement)
    ..overClass = null
    ..acceptDraggables.addAll(acceptDraggables);
    
    // Save the subscription for onDragOver so we can pause and resume it.
    StreamSubscription overSubscription = dropzone.onDragOver.listen((DropzoneEvent event) {
      // Return if drag is not from this sortable.
      if (_placeholder == null) return;
      _logger.finest('onDragOver');
      
      _placeholder.showPlaceholderForBiggerDropzone(dropzone, event.mouseEvent, 
          _isGrid);
    }); // start in paused state

    dropzone.onDragEnter.listen((DropzoneEvent event) {
      // Return if drag is not from this sortable.
      if (_placeholder == null) return;
      _logger.finest('onDragEnter');
      
      if (_placeholder.isDropzoneHigher(event.dropzone)) {
        _logger.finest('dropzone is higher than placeholder, resuming onDragOver events');
        overSubscription.resume();
      } else if (_isGrid && _placeholder.isDropzoneWider(event.dropzone)) {
        _logger.finest('dropzone is wider than placeholder, resuming onDragOver events');
        overSubscription.resume();
      } else {
        _placeholder.showPlaceholder(event.dropzone);
        _logger.finest('dropzone is not bigger than placeholder, pausing onDragOver events');
        if (!overSubscription.isPaused) {
          overSubscription.pause();
        }
      }
    });
  }
  
  void _showDraggable(Position newPosition) {
    _placeholder.placeholderElement.remove();
    newPosition.insert(currentDraggable.element);
    
    // Fire sortable complete event
    if (newPosition != _originalPosition) {
      _logger.finest('firing onSortableComplete event');
      
      if (_onSortableComplete.hasListener 
        && !_onSortableComplete.isClosed
        && !_onSortableComplete.isPaused) {
      _onSortableComplete.add(new SortableResult(currentDraggable, 
          _originalPosition, _placeholder.placeholderPosition));
      }
    }
  }
}

class _Placeholder {
  Element placeholderElement;
  
  /// Position of the placeholder.
  Position placeholderPosition;
  
  /// Fired when a drag element has been dropped in this placeholder.
  Stream<_Placeholder> get onDrop => _onDrop.stream;
  
  StreamController<_Placeholder> _onDrop = 
      new StreamController<_Placeholder>(sync: true);
  
  /**
   * Creates a new placeholder for the specified [draggableElement].
   */
  _Placeholder(Element draggableElement, String placeholderClass, 
      bool forcePlaceholderSize) {
    placeholderElement = new Element.tag(draggableElement.tagName);
    if (placeholderClass != null) {
      placeholderElement.classes.add(placeholderClass);
    }
    
    if (forcePlaceholderSize) {
      // Placeholder receives the computed size from the dragged element.
      placeholderElement.style.height = draggableElement.getComputedStyle().height; 
      placeholderElement.style.width = draggableElement.getComputedStyle().width;
    }
    
    // Make the placeholder to a dropzone so we can drop inside.
    new Dropzone(placeholderElement)
    ..overClass = null
    
    ..onDrop.listen((DropzoneEvent event) {
      _logger.finest('placeholder onDrop');
      _onDrop.add(this);
    });
  }
  
  /**
   * Returns true if the [dropzone]'s height is greater than this placeholder's.
   * If the placeholder hasn't been added and thus has a size of 0, false is
   * returned.
   */
  bool isDropzoneHigher(Dropzone dropzone) {
    return placeholderElement.clientHeight > 0 
        && dropzone.element.clientHeight > placeholderElement.clientHeight;
  }
  
  /**
   * Returns true if the [dropzone]'s width is greater than this placeholder's.
   * If the placeholder hasn't been added and thus has a size of 0, false is
   * returned.
   */
  bool isDropzoneWider(Dropzone dropzone) {
    return placeholderElement.clientWidth > 0 
        && dropzone.element.clientWidth > placeholderElement.clientWidth;
  }
  
  /**
   * Shows the placeholder at the position of [dropzone].
   */
  void showPlaceholder(Dropzone dropzone) {
    _logger.finest('showPlaceholder');
    Position dropzonePosition = new Position(dropzone.element.parent,
        html5.getElementIndexInParent(dropzone.element));
    
    _doShowPlaceholder(dropzone, dropzonePosition);
  }
  
  /**
   * Shows the placeholder at the position of [dropzone] ONLY if mouse is not
   * in the disabled region of the bigger [dropzone].
   */
  void showPlaceholderForBiggerDropzone(Dropzone dropzone, MouseEvent event, 
                                        bool isGrid) {
    Position dropzonePosition = new Position(dropzone.element.parent,
        html5.getElementIndexInParent(dropzone.element));
    
    if (isDropzoneHigher(dropzone)) {
      if (_isInDisabledVerticalRegion(dropzone, dropzonePosition, event)) {
        return;
      }
    }
    
    if (isGrid) {
      if (isDropzoneWider(dropzone)) {
        if (_isInDisabledHorizontalRegion(dropzone, dropzonePosition, event)) {
          return; 
        }
      }
    }
    _doShowPlaceholder(dropzone, dropzonePosition);
  }
  
  void _doShowPlaceholder(Dropzone dropzone, Position dropzonePosition) {
    // Show placeholder at the position of dropzone.
    placeholderPosition = dropzonePosition;
    _logger.finest('showing placeholder at index ${placeholderPosition.index}');
    placeholderElement.remove(); // Might already be at a different position.
    placeholderPosition.insert(placeholderElement);
    
    // Make sure the draggable element is removed.
    currentDraggable.element.remove();
    
    // Dropzone was either moved or removed (if it is the draggable itself).
    // Thus the drag over counter must be reset.
    dropzone.resetDragOverElements();
  }
  
  /**
   * Returns true if the mouse is in the disabled vertical region of the 
   * dropzone.
   */
  bool _isInDisabledVerticalRegion(Dropzone dropzone, Position dropzonePosition, 
                                   MouseEvent event) {
    if (placeholderPosition != null && placeholderPosition > dropzonePosition) {
      // Current placeholder position is after the new dropzone position.
      // --> Disabled region is in the bottom part of the dropzone.
      
      // Calc the mouse position relative to the dropzone.
      num mouseRelativeTop = event.page.y - css.getTopOffset(dropzone.element);      
      if (mouseRelativeTop > placeholderElement.clientHeight) {
        return true; // In disabled region.
      }
    }
    return false;
  }
  
  /**
   * Returns true if the mouse is in the disabled horizontal region of the 
   * dropzone. This check is only necessary for grids.
   */
  bool _isInDisabledHorizontalRegion(Dropzone dropzone, Position dropzonePosition, 
                                     MouseEvent event) {
    // Calc the mouse position relative to the dropzone.
    num mouseRelativeLeft = event.page.x - css.getLeftOffset(dropzone.element);      
    
    if (placeholderPosition != null && placeholderPosition > dropzonePosition) {
      // Current placeholder position is after the new dropzone position.
      // --> Disabled region is in the right part of the dropzone.
      if (mouseRelativeLeft > placeholderElement.clientWidth) {
        return true; // In disabled region.
      }
    }
    if (placeholderPosition != null && placeholderPosition < dropzonePosition) {
      // Current placeholder position is after the new dropzone position.
      // --> Disabled region is in the left part of the dropzone.
      if (mouseRelativeLeft < placeholderElement.clientWidth) {
        return true; // In disabled region.
      }
    }
    return false;
  }
}

/**
 * Defines a position of an element in its [parent].
 */
class Position {
  Element parent;
  int index;
  
  Position(this.parent, this.index);
  
  /**
   * Inserts the specified [element] as a child of [parent] at [index].
   */
  void insert(Element element) {
    parent.children.insert(index, element);
  }

  /**
   * Returns true if this position has a greater index than [other].
   * Returns null if the two positions cannot be compared because either they 
   * have different parents.
   */
  bool operator>(Position other) {
    if (other.parent == parent) {
      return index > other.index;
    }
    return null;
  }
  
  /**
   * Returns true if this position has a smaller index than [other].
   * Returns null if the two positions cannot be compared because either they 
   * have different parents.
   */
  bool operator<(Position other) {
    if (other.parent == parent) {
      return index < other.index;
    }
    return null;
  }
  
  @override
  int get hashCode {
    int result = 17;
    result = 37 * result + parent.hashCode;
    result = 37 * result + index.hashCode;
    return result;
  }

  @override
  bool operator==(other) {
    if (identical(other, this)) return true;
    return (other is Position
        && other.parent == parent 
        && other.index == index);
  }
}

/**
 * Result used to carry information about a completed sortable drag-and-drop 
 * operation. The [draggable] was moved and has the [newPosition]. Also provides 
 * info about the [originalPosition].
 */
class SortableResult {
  Draggable draggable;
  Position originalPosition;
  Position newPosition;
  
  SortableResult(this.draggable, this.originalPosition, this.newPosition);
}