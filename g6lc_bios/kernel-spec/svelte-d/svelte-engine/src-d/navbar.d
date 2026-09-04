module navbar;

import libwasm;
import pglite;

class SomeException : Exception {
  @trusted:
  this(string msg, string file = __FILE__, size_t line = __LINE__) {
    super(msg, file, line);
  }
}

@safe struct NavBar {
    nothrow:

  @child NavBarStart start;
  @child NavBarCenter center;
  @child NavBarEnd end;

  struct NavBarEnd {
    @child Link link;

    struct Link {
      @prop!"textContent" string name = "Button";
      @callback!"click" void onClick(MouseEvent ev) @trusted {
        console.log("Button clicked");
        // wasm-eh cell: D try/catch must remain (not nothrow-optimized away).
        try
        {
          throw new SomeException("svelte-engine-eh");
        }
        catch (Exception e)
        {
          console.log(e.msg);
        }

        JSON res = PgLite().query("  CREATE TABLE IF NOT EXISTS test (
    id SERIAL PRIMARY KEY,
    name TEXT
  );
  INSERT INTO test (name) VALUES ('test');
  SELECT * FROM test;");
        console.log(res);
      }


      //
      @style!"btn" mixin NodeDef!"a";
    }
    //
    @style!"navbar-end" mixin NodeDef!"div";
  }

  struct NavBarCenter {
    @child Menu menu;

    struct Menu { nothrow:
      import libwasm.array;

      @child UnorderedList!MenuItem menulist;

      void construct() {
        menulist.put(new MenuItem("Item 1"));
        menulist.put(new MenuItem("Item 2"));
      }

      @connect!("menulist.items","link.clicker") void onEdit(size_t idx, string name) {
        console.log("Clicked: " ~ name);
      }

      struct MenuItem { nothrow:
        @child Link link;
        //@child DropDown dropdown;
        this(string name) {
          link = Link(name);
          //dropdown = DropDown(["Submenu 1", "Submenu 2"]);
        }

        struct Link { nothrow:
          @prop!"textContent" string name;
          mixin Slot!("clicker", string);

          @callback!"click" void onClick(MouseEvent ev) {
            console.log("onClick");
            this.emit(clicker, this.name);
          }
          //
          mixin NodeDef!"a";
        }

/*
        @visible!"link" bool showLink() {
          link != Link.init;
        }
        @visible!"dropdown" bool showDropdown() {
          dropdown != DropDown.init;
        }

        struct DropDown {
          @child Summary summary = Summary("Parent");
          @child SubMenu submenu;

          this(string[] links) {
            submenu = SubMenu(links);
          }

          struct Summary {
            @child string textContent = "Parent";
            //
            mixin NodeDef!"summary";
          }

          struct SubMenu {
            import libwasm.array;
            @child UnorderedList!SubMenuItem items;

            void construct(string[] items) {
              foreach(item; items) this.items ~= SubMenuItem(item);
            }

            struct SubMenuItem {
              @child SubMenuItemLink link;

              this(string link) {
                this.link.textContent = link;
              }

              struct SubMenuItemLink {
                @child string textContent;
                //
                mixin NodeDef!"a";
              }
              //
              mixin NodeDef!"li";
            }

            //
            @style!"p-2" mixin NodeDef!"ul";
          }

          //
          mixin NodeDef!"details";
        }*/
        //
        @style!"menu-item" mixin NodeDef!"li";
      }

      //
      @style!"menu menu-horizontal px-1" mixin NodeDef!"ul";
    }

    //
    @style!"navbar-center hidden lg:flex" mixin NodeDef!"div";
  }

  struct NavBarStart { nothrow:
    @child DropDown dropdown;
    @child Logo logo;
    User userdata = User("John Doe", 1234);

    struct User {
      string name;
      int id;
    }

    struct Logo {
      @prop!"innerText" string innerText = "PsxAI";

      //
      @style!"btn btn-ghost text-xl" mixin NodeDef!"a";
    }
    struct DropDown { nothrow:
      @child Hamburger hamburger_menu;
      @child Menu menu;
      
      struct Menu { nothrow:
      
        @attr!"id" string id = "popover-1";
        @attr!"tabindex" int tabindex = 0;

        @child MenuItem item1 = MenuItem("Item 1");
        @child MenuItem item2 = MenuItem("Item 2");

        @connect!"item1.clicker" @connect!"item2.clicker"
        void onEdit(User udata, string name) {
          console.log("OnEdit");
          console.log("Clicked: " ~ name);
          console.log("Got user: " ~ udata.name);
        }

        struct MenuItem {
          @child Link link;
          mixin Slot!("clicker", User, string);
          @inject!"userdata" User* user;

          this(string name) {
            link = Link(name);
          }

          @callback!"click" void onClick(MouseEvent ev) {
            console.log("clickCallback");
            this.emit(clicker, *user, this.link.name);
          }

          struct Link { nothrow:
            @prop!"textContent" string name;
            //
            mixin NodeDef!"a";
          }
          //
          mixin NodeDef!"li";
        }
      
        //
        @style!"dropdown-content menu bg-base-100 rounded-box z-1 mt-3 w-52 p-2 shadow" mixin NodeDef!"ul";
      }

      struct Hamburger { nothrow:
        @attr!"tabindex" int tabindex = 0;
        @attr!"role" string role = "button";
        @prop!"innerHTML" string innerHTML;

        void construct() {
          this.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor"> <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h8m-8 6h16" /> </svg>`;
        }
        //
        @style!"btn m-1" mixin NodeDef!"div";
      }

      //
      @style!"dropdown" mixin NodeDef!"div";
    }
    
    
    //
    @style!"navbar-start" mixin NodeDef!"div";
  }

  //
  @style!"navbar bg-base-100 shadow-sm" mixin NodeDef!"div";
}
