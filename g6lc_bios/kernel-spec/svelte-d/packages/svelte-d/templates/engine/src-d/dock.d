module dock;

import libwasm;

@safe struct Dock
{
nothrow:

  @style!"dock-active" @child Button btn1;
  @child Button btn2;
  @child Button btn3;

  void construct()
  {
    btn1 = Button("Home", `<svg class="size-[1.2em]" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><g fill="currentColor" stroke-linejoin="miter" stroke-linecap="butt"><polyline points="1 11 12 2 23 11" fill="none" stroke="currentColor" stroke-miterlimit="10" stroke-width="2"></polyline><path d="m5,13v7c0,1.105.895,2,2,2h10c1.105,0,2-.895,2-2v-7" fill="none" stroke="currentColor" stroke-linecap="square" stroke-miterlimit="10" stroke-width="2"></path><line x1="12" y1="22" x2="12" y2="18" fill="none" stroke="currentColor" stroke-linecap="square" stroke-miterlimit="10" stroke-width="2"></line></g></svg>`);
    btn2 = Button("Inbox", `<svg class="size-[1.2em]" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><g fill="currentColor" stroke-linejoin="miter" stroke-linecap="butt"><polyline points="3 14 9 14 9 17 15 17 15 14 21 14" fill="none" stroke="currentColor" stroke-miterlimit="10" stroke-width="2"></polyline><rect x="3" y="3" width="18" height="18" rx="2" ry="2" fill="none" stroke="currentColor" stroke-linecap="square" stroke-miterlimit="10" stroke-width="2"></rect></g></svg>`);
    btn3 = Button("Settings", `<svg class="size-[1.2em]" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><g fill="currentColor" stroke-linejoin="miter" stroke-linecap="butt"><circle cx="12" cy="12" r="3" fill="none" stroke="currentColor" stroke-linecap="square" stroke-miterlimit="10" stroke-width="2"></circle><path d="m22,13.25v-2.5l-2.318-.966c-.167-.581-.395-1.135-.682-1.654l.954-2.318-1.768-1.768-2.318.954c-.518-.287-1.073-.515-1.654-.682l-.966-2.318h-2.5l-.966,2.318c-.581.167-1.135.395-1.654.682l-2.318-.954-1.768,1.768.954,2.318c-.287.518-.515,1.073-.682,1.654l-2.318.966v2.5l2.318.966c.167.581.395,1.135.682,1.654l-.954,2.318,1.768,1.768,2.318-.954c.518.287,1.073.515,1.654.682l.966,2.318h2.5l.966-2.318c.581-.167,1.135-.395,1.654-.682l2.318.954,1.768-1.768-.954-2.318c.287-.518.515-1.073.682-1.654l2.318-.966Z" fill="none" stroke="currentColor" stroke-linecap="square" stroke-miterlimit="10" stroke-width="2"></path></g></svg>`);
  }

  mixin Slot!("navigate", string);

  @connect!"btn1.clicker" @connect!"btn2.clicker" @connect!"btn3.clicker"
  void onBtnClick(string name)
  {
    btn1.update.removeClass("dock-active");
    btn2.update.removeClass("dock-active");
    btn3.update.removeClass("dock-active");
    final switch (name)
    {
    case "Home":
      btn1.update.addClass("dock-active");
      break;
    case "Inbox":
      btn2.update.addClass("dock-active");
      break;
    case "Settings":
      btn3.update.addClass("dock-active");
      break;
    }
    this.emit(navigate, name);
  }

  struct Button
  {
    nothrow:
    @child Svg svg;
    @child Label label;
    mixin Slot!("clicker", string);

    @callback!"click" void onClick(MouseEvent ev)
    {
      this.emit(clicker, this.label.name);
      console.log(ev);
    }

    this(string label_, string svg_)
    {
      this.svg.innerHTML = svg_;
      this.label.name = label_;
    }

    struct Svg
    {
      @prop!"innerHTML" string innerHTML;
      //
      mixin NodeDef!"div";
    }

    struct Label
    {
      @prop!"innerText" string name;
      //
      @style!"dock-label" mixin NodeDef!"div";
    }

    //
    mixin NodeDef!"button";
  }
  //
  @style!"dock" @style!"dock-xl"
  mixin NodeDef!"div";
}
