import SwiftUI

/// 登录与注册共用一页，按原型 `vLogin` 布局，底部链接切换两种模式。
struct AuthView: View {
    @EnvironmentObject private var accounts: AccountStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isRegistering = false
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 浅色模式 Volt 对比度不够，「Flow」改用正文色，和原型一致
            let flow = Text("Flow")
                .foregroundStyle(colorScheme == .light ? Palette.text : Palette.volt)
            Text("Rep\(flow)")
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(Palette.text)
            Text(isRegistering ? "创建账号，训练记录会归到这个账号" : "用手表自动计次的训练记录")
                .foregroundStyle(Palette.text2)
                .padding(.bottom, 18)

            field("用户名") {
                TextField("用户名", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            field("密码") {
                SecureField("密码", text: $password)
                    .textContentType(isRegistering ? .newPassword : .password)
            }
            Text(errorMessage ?? " ")
                .font(.subheadline)
                .foregroundStyle(Palette.red)
                .padding(.leading, 4)

            Button(action: submit) {
                if isSubmitting {
                    ProgressView()
                } else {
                    Text(isRegistering ? "注册并登录" : "登录")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isSubmitting)

            Spacer()
            Button {
                isRegistering.toggle()
                errorMessage = nil
            } label: {
                let target = Text(isRegistering ? "登录" : "注册").bold()
                    .foregroundStyle(Palette.text)
                Text("\(isRegistering ? "已有账号？" : "没有账号？")\(target)")
                    .foregroundStyle(Palette.text2)
                    .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 20)
        .padding(.top, 70)
        .pageBackground()
        .onSubmit(submit)
        // 退出或登录失效后回到这里，多半是同一个人要重新登录
        .onAppear {
            if username.isEmpty { username = accounts.lastAccount()?.username ?? "" }
        }
    }

    private func field(_ label: String, @ViewBuilder input: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.text2)
                .padding(.leading, 4)
            input()
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        if let message = AccountStore.inputError(
            username: username, password: password, isRegistering: isRegistering)
        {
            errorMessage = message
            return
        }
        errorMessage = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                if isRegistering {
                    try await accounts.register(username: username, password: password)
                } else {
                    try await accounts.login(username: username, password: password)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
