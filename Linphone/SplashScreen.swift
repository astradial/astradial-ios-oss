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
			Color(.systemBackground)
				.ignoresSafeArea()

			VStack(spacing: 14) {
				Image(systemName: "phone.badge.waveform.fill")
					.font(.system(size: 64))
					.foregroundStyle(.tint)
				Text("Astradial")
					.font(.title.weight(.bold))
			}

			ProgressView()
				.controlSize(.small)
				.offset(y: 110)
				.opacity(showSpinner ? 1 : 0)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.ignoresSafeArea(.all)
	}
}

#Preview {
	SplashScreen()
}
