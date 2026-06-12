/*
 * Copyright (c) 2010-2023 Belledonne Communications SARL.
 *
 * This file is part of Linphone
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import SwiftUI

struct SplashScreen: View {
	var showSpinner: Bool = false

	var body: some View {
		ZStack {
			Color(red: 0x19 / 255.0, green: 0, blue: 1)
				.ignoresSafeArea()

			Image("AstradialLogo")
				.resizable()
				.scaledToFit()
				.frame(width: 180, height: 180)

			ProgressView()
				.controlSize(.small)
				.tint(.white)
				.offset(y: 150)
				.opacity(showSpinner ? 1 : 0)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.ignoresSafeArea(.all)
	}
}

#Preview {
	SplashScreen()
}
