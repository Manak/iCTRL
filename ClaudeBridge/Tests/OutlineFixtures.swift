import Foundation

/// Device text shaped like real screens: the same element types, nesting,
/// identifiers, invisible marks and frames as captured on the phone, with
/// made-up words in place of anyone's messages.
enum OutlineFixtures {
    /// A WhatsApp chat on a 466 x 678 screen, scrolled to the bottom: the
    /// header in a navigation bar, a recycled message list whose cells sit
    /// above the screen, a bottom bar outside any bar element, and a side
    /// toolbar. One message has line breaks in it, as the device sends them.
    static let chat = [
        "Application, label: '\u{200E}WhatsApp', {{0, 0}, {466, 678}}",
        "  Window, {{0, 0}, {466, 678}}",
        "    Other, {{0, 0}, {466, 678}}",
        "      Toolbar, label: 'Toolbar', {{0, 0}, {466, 678}}",
        "      Toolbar, label: 'Toolbar', {{0, 0}, {466, 678}}",
        "      NavigationBar, id: 'WDSNavigationBar', {{0, 24}, {466, 58}}",
        "        StaticText, label: 'Alex', id: 'NavigationBar_ConversationHeader', {{20, 26}, {362, 44}}",
        "          Other, label: '\u{200E}Profile picture', value: '\u{200E}View contact info', id: 'NavigationBar_ProfilePictureButton', {{16, 27}, {41, 41}}",
        "            Image, {{16, 27}, {40, 40}}",
        "          Button, label: 'Alex', value: '\u{200E}online', id: 'NavigationBar_HeaderViewButton', {{65, 26}, {317, 44}}",
        "          Other, label: 'Alex', id: 'NavigationBar_TitleLabel', {{65, 31}, {47, 19}}",
        "            StaticText, label: 'Alex', {{65, 31}, {47, 19}}",
        "          StaticText, label: '\u{200E}online', id: 'NavigationBar_CaptionLabel', {{65, 49}, {47, 14}}",
        "            StaticText, label: '\u{200E}online', {{65, 49}, {47, 14}}",
        "      Other, id: 'ChatScreen_WallpaperView', {{0, 0}, {466, 678}}",
        "        Image, id: 'DoodleOverlay', {{-26, -37}, {518, 753}}",
        "      Table, id: 'ChatMessagesTableView', {{0, 0}, {466, 678}}",
        "        Cell, id: 'WAMessageBubbleTableViewCell', {{0, -950}, {466, 50}}",
        "          Other, label: '\u{200E}Your message, see you at 7, 10 November at 12:09, \u{200E}Sent to Alex, \u{200E}Read', {{150, -945}, {200, 40}}",
        "            Other, id: 'MessageStatusSliceView', {{150, -926}, {200, 19}}",
        "        Cell, id: 'WAMessageBubbleTableViewCell', {{0, -850}, {466, 150}}",
        "          Button, label: 'HD', id: 'UIImageView_hdIcon', {{0, 84}, {20, 20}}",
        "          Button, {{0, 84}, {60, 60}}",
        "          Image, id: 'mediaDownloadSmall', {{0, 84}, {20, 20}}",
        "          Other, label: '\u{200E}Forwarded.",
        "\u{200E}Photo, 10 November at 12:13, \u{200E}Received from Alex', {{16, -845}, {216, 140}}",
        "            Other, id: 'MessageStatusSliceView', {{16, -720}, {216, 19}}",
        "          Button, label: '\u{200E}Forward', id: 'MessageQuickActionBubble_Forward', {{0, 84}, {30, 30}}",
        "        Cell, id: 'WAMessageBubbleTableViewCell', {{0, -650}, {466, 50}}",
        "          Other, label: '\u{200E}Your message, Ok, 10 November at 12:14, \u{200E}Sent to Alex, \u{200E}Read', {{300, -645}, {104, 38}}",
        "        StaticText, label: '\u{200E}Today', {{173, 96}, {35, 14}}",
        "        Cell, id: 'WAMessageBubbleTableViewCell', {{0, -130}, {466, 663}}",
        "          Other, label: '\u{200E}message, Plan for Saturday",
        "•  Meet at the court, 9am.",
        "•  Bring two tubes, one spare racket.",
        "",
        "•  Lunch after, if it's not raining., 09:58, \u{200E}Received from Alex', {{16, -124}, {279, 651}}",
        "            Other, id: 'MessageStatusSliceView', {{16, 507}, {279, 19}}",
        "        Cell, id: 'WAMessageBubbleTableViewCell', {{0, 532}, {466, 50}}",
        "          Other, label: '\u{200E}Your message, Sounds good, 10:09, \u{200E}Sent to Alex, \u{200E}Delivered', {{262, 538}, {104, 38}}",
        "            Other, id: 'MessageStatusSliceView', {{262, 557}, {104, 19}}",
        "        Other, label: 'Vertical scroll bar, 4 pages', value: '100%', {{349, 82}, {30, 502}}",
        "      Other, label: '\u{200E}Share media', {{16, 598}, {40, 40}}",
        "        Button, label: '\u{200E}Share media', id: 'ChatBar_AttachMediaButton', {{16, 598}, {40, 40}}",
        "      TextView, label: '\u{200E}Compose message', value: '  ', id: 'ChatBar_ComposerTextView', {{73, 605}, {188, 25}}",
        "        Other, id: '_UITextSelectionRangeAdjustmentContainerView', {{73, 605}, {0, 0}}",
        "          Other, id: 'com.apple.text.grabber.leading', {{73, 605}, {0, 0}}",
        "      Other, label: '\u{200E}Camera', {{278, 598}, {40, 40}}",
        "        Button, label: '\u{200E}Camera', id: 'ChatBar_CameraButton', {{278, 598}, {40, 40}}",
        "      Toolbar, label: 'Toolbar', {{0, 0}, {466, 678}}",
        "        Button, label: '49', id: 'BackButton', {{399, 179}, {38, 38}}",
        "        Button, label: '\u{200E}Start video call with Alex', id: 'NavigationBar_VideoCallButton', {{399, 239}, {38, 38}}",
    ].joined(separator: "\n")

    /// A long food menu like Grab's, on a 393 x 852 screen: a sticky
    /// header, category tabs, a table of dish cells (children of off-screen
    /// cells report the list's origin), quantity steppers nested inside each
    /// Add button, a disabled order button, and a basket bar.
    static func menu(dishes: Int = 120) -> String {
        var lines = [
            "Application, label: 'Grab', {{0, 0}, {393, 852}}",
            "  Other, id: 'food_menu_redesign_container_view', {{0, 0}, {393, 852}}",
            "    Table, id: 'food_merchant_menu_tableView', {{0, 0}, {393, 852}}",
            "      Other, label: 'Good Service, Burger Place, 4.3, (3K+), Halal, From 36 mins', {{0, 90}, {393, 80}}",
            "      ScrollView, {{0, 170}, {393, 50}}",
            "        Other, id: 'food_merchant_group_order_button', {{10, 175}, {120, 40}}",
            "          Button, label: 'Group Order', disabled, {{10, 175}, {120, 40}}",
            "            StaticText, label: 'Group Order', {{20, 185}, {100, 20}}",
            "        Button, label: 'Share', {{140, 175}, {80, 40}}",
            "          StaticText, label: 'Share', {{150, 185}, {60, 20}}",
        ]
        for i in 0..<dishes {
            let y = 230 + i * 120
            let onScreen = y + 120 <= 852
            func child(_ x: Int, _ dy: Int, _ w: Int, _ h: Int) -> String {
                onScreen ? "{{\(x), \(y + dy)}, {\(w), \(h)}}" : "{{0, 0}, {\(w), \(h)}}"
            }
            if i % 10 == 0 {
                lines.append("      Other, id: 'food_menu_category_header_\(i / 10)', {{0, \(y - 30)}, {393, 30}}")
                lines.append("        StaticText, label: 'Category \(i / 10 + 1)', \(child(16, -25, 200, 20))")
            }
            lines += [
                "      Cell, id: 'food_menu_dish_cell', {{0, \(y)}, {393, 120}}",
                "        Image, id: 'image_loaded_successful', \(child(10, 10, 100, 100))",
                "        StaticText, label: 'Dish \(i + 1) Meal', \(child(120, 10, 200, 20))",
                "        StaticText, label: 'Crispy, juicy and served with \"house\" sauce.', \(child(120, 35, 250, 40))",
                "        StaticText, label: '\(String(format: "%.2f", 5.5 + Double(i % 7)))', \(child(120, 85, 60, 20))",
                "        Button, label: 'Add', \(child(330, 80, 50, 30))",
                "          Button, id: 'food_menu_dish_quick_add_button', \(child(330, 80, 50, 30))",
                "          Button, label: '0', id: 'food_menu_dish_quick_add_button', \(child(330, 80, 50, 30))",
                "            StaticText, label: '0', \(child(350, 85, 10, 20))",
            ]
        }
        lines += [
            "      Other, label: 'Vertical scroll bar, 20 pages', value: '0%', {{380, 90}, {10, 700}}",
            "  NavigationBar, {{0, 20}, {393, 65}}",
            "    Button, label: 'Back', {{8, 30}, {44, 44}}",
            "    Button, label: 'Search', {{340, 30}, {44, 44}}",
            "  Button, label: 'View basket', id: 'food_menu_view_basket_button', {{16, 780}, {361, 50}}",
            "    StaticText, label: 'View basket', {{150, 795}, {100, 20}}",
            "    StaticText, label: 'S$0.00', {{300, 795}, {60, 20}}",
        ]
        return lines.joined(separator: "\n")
    }
}
