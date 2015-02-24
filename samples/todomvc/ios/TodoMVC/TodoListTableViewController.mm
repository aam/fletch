// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#import "TodoListTableViewController.h"
#import "AddTodoItemViewController.h"
#import "TodoItem.h"

#include "todomvc_presenter.h"

// Host-side implementation of the todo-list presenter.
// This class is responsible for mapping Dart-side changes to the presenter
// model of the host implementation, in this case, a table-view presenting a
// list of TodoItem objects.
class TodoMVCPresenterImpl : public TodoMVCPresenter {
public:
  TodoMVCPresenterImpl(TodoListTableViewController* controller)
    : controller_(controller) {
    items_ = [[NSMutableArray alloc] init];
  }

  NSArray* items() { return items_; }

protected:
  // Patch apply callbacks.
  virtual void enterPatch() {
    context_ = IN_LIST;
    index_ = 0;
  }

  virtual void enterConsFst() {
    context_ = (context_ == IN_LIST) ? IN_ITEM : IN_TITLE;
  }

  virtual void enterConsSnd() {
    if (context_ == IN_LIST) {
      ++index_;
    } else {
      context_ = IN_STATUS;
    }
  }

  virtual void updateNode(const Node& node) {
    TodoItem *item;
    switch (context_) {
      case IN_TITLE:
        item = [items_ objectAtIndex:index_];
        item.itemName = decodeStr(node.getStr());
        break;
      case IN_STATUS:
        item = [items_ objectAtIndex:index_];
        item.completed = node.getBool();
        break;
      case IN_ITEM:
        item = newItem(node);
        [items_ insertObject:item atIndex:index_];
        break;
      case IN_LIST:
        resizeTo(index_);
        addItems(node);
        break;
      default:
        abort();
    }
    // TODO: Selectively reload only the affected rows.
    [controller_.tableView reloadData];
  }

private:
  void resizeTo(unsigned long newLength) {
    unsigned long length = [items_ count];
    if (newLength < length) {
      [items_ removeObjectsInRange:NSMakeRange(newLength, length - newLength)];
    }
  }

  NSString* decodeStr(Str str) {
    List<uint8_t> chars = str.getChars();
    unsigned length = chars.length();
    unichar* tmp = new unichar[length];
    for (int i = 0; i < chars.length(); ++i) {
      tmp[i] = chars[i];
    }
    return [[NSString alloc]
            initWithCharactersNoCopy:tmp
                              length:length
                        freeWhenDone:YES];
  }

  TodoItem* newItem(const Node& node) {
    TodoItem *item = [[TodoItem alloc] init];
    Cons cons = node.getCons();
    item.itemName = decodeStr(cons.getFst().getStr());
    item.completed = cons.getSnd().getBool();
    return item;
  }

  void addItem(const Node& node) {
    TodoItem *item = newItem(node);
    [items_ addObject:item];
  }

  void addItems(const Node& node) {
    if (node.isNil()) return;
    Cons cons = node.getCons();
    addItem(cons.getFst());
    addItems(cons.getSnd());
  }

  enum Context { IN_LIST, IN_ITEM, IN_TITLE, IN_STATUS };
  Context context_;
  int index_;
  NSMutableArray* items_;
  TodoListTableViewController* controller_;
};

@interface TodoListTableViewController ()

@property TodoMVCPresenterImpl *impl;

@end

@implementation TodoListTableViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  // Instantiate host-side implementation of the presenter.
  self.impl = new TodoMVCPresenterImpl(self);
  // Link display refresh to syncronization of the presenter.
  CADisplayLink* link = [CADisplayLink
                         displayLinkWithTarget:self
                                      selector:@selector(refreshDisplay:)];
  [link setFrameInterval:1];
  [link addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
}

- (void)refreshDisplay:(CADisplayLink *)sender {
  self.impl->sync();
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (IBAction)unwindToList:(UIStoryboardSegue *)segue {
  AddTodoItemViewController *source = [segue sourceViewController];
  TodoItem *item = source.todoItem;
  if (item == nil) return;
  char title[256];
  [item.itemName getCString:title
                  maxLength:256
                   encoding:NSASCIIStringEncoding];
  self.impl->createItem(title);
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  return [self.impl->items() count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell =
      [tableView dequeueReusableCellWithIdentifier:@"ListPrototypeCell"
                                      forIndexPath:indexPath];
  TodoItem *todoItem = [self.impl->items() objectAtIndex:indexPath.row];
  cell.textLabel.text = todoItem.itemName;
  cell.accessoryType = todoItem.completed
    ? UITableViewCellAccessoryCheckmark
    : UITableViewCellAccessoryNone;
  return cell;
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:NO];
  // TODO: this should toggle the status.
  self.impl->completeItem(indexPath.row);
}

@end
