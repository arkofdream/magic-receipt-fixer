export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.15"
  }
  public: {
    Tables: {
      customers: {
        Row: {
          address: string
          city: string
          created_at: string
          district: string
          email: string
          id: string
          neighborhood: string
          phone: string
          tax_office: string
          title: string
          updated_at: string
          user_id: string
          vkn_tckn: string
        }
        Insert: {
          address?: string
          city?: string
          created_at?: string
          district?: string
          email?: string
          id?: string
          neighborhood?: string
          phone?: string
          tax_office?: string
          title: string
          updated_at?: string
          user_id: string
          vkn_tckn: string
        }
        Update: {
          address?: string
          city?: string
          created_at?: string
          district?: string
          email?: string
          id?: string
          neighborhood?: string
          phone?: string
          tax_office?: string
          title?: string
          updated_at?: string
          user_id?: string
          vkn_tckn?: string
        }
        Relationships: []
      }
      efatura_connection_settings: {
        Row: {
          active_provider: string
          created_at: string
          gib_enabled: boolean
          gib_environment: string
          gib_last_error: string
          gib_last_tested_at: string | null
          gib_password_encrypted: string | null
          gib_status: string
          gib_username: string
          integrator_api_key_encrypted: string | null
          integrator_api_username: string
          integrator_base_url: string
          integrator_enabled: boolean
          integrator_last_error: string
          integrator_last_tested_at: string | null
          integrator_provider: string
          integrator_status: string
          updated_at: string
          user_id: string
        }
        Insert: {
          active_provider?: string
          created_at?: string
          gib_enabled?: boolean
          gib_environment?: string
          gib_last_error?: string
          gib_last_tested_at?: string | null
          gib_password_encrypted?: string | null
          gib_status?: string
          gib_username?: string
          integrator_api_key_encrypted?: string | null
          integrator_api_username?: string
          integrator_base_url?: string
          integrator_enabled?: boolean
          integrator_last_error?: string
          integrator_last_tested_at?: string | null
          integrator_provider?: string
          integrator_status?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          active_provider?: string
          created_at?: string
          gib_enabled?: boolean
          gib_environment?: string
          gib_last_error?: string
          gib_last_tested_at?: string | null
          gib_password_encrypted?: string | null
          gib_status?: string
          gib_username?: string
          integrator_api_key_encrypted?: string | null
          integrator_api_username?: string
          integrator_base_url?: string
          integrator_enabled?: boolean
          integrator_last_error?: string
          integrator_last_tested_at?: string | null
          integrator_provider?: string
          integrator_status?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      invoices: {
        Row: {
          cancel_date: string | null
          created_at: string
          currency: string
          customer: Json
          ettn: string
          exchange_rate: number
          gib_approval_date: string | null
          grand_total: number
          id: string
          invoice_date: string
          invoice_number: string
          items: Json
          notes: string
          payment_info: string
          status: string
          subtotal: number
          taxable_amount: number
          total_discount: number
          total_tevkifat: number
          total_vat: number
          type: string
          updated_at: string
          user_id: string
        }
        Insert: {
          cancel_date?: string | null
          created_at?: string
          currency?: string
          customer?: Json
          ettn: string
          exchange_rate?: number
          gib_approval_date?: string | null
          grand_total?: number
          id?: string
          invoice_date?: string
          invoice_number: string
          items?: Json
          notes?: string
          payment_info?: string
          status?: string
          subtotal?: number
          taxable_amount?: number
          total_discount?: number
          total_tevkifat?: number
          total_vat?: number
          type?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          cancel_date?: string | null
          created_at?: string
          currency?: string
          customer?: Json
          ettn?: string
          exchange_rate?: number
          gib_approval_date?: string | null
          grand_total?: number
          id?: string
          invoice_date?: string
          invoice_number?: string
          items?: Json
          notes?: string
          payment_info?: string
          status?: string
          subtotal?: number
          taxable_amount?: number
          total_discount?: number
          total_tevkifat?: number
          total_vat?: number
          type?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      pos_sales: {
        Row: {
          created_at: string
          description: string
          document_no: string
          gross_amount: number
          id: string
          net_amount: number
          payment_type: string
          sale_date: string
          updated_at: string
          user_id: string
          vat_amount: number
          vat_rate: number
        }
        Insert: {
          created_at?: string
          description?: string
          document_no?: string
          gross_amount?: number
          id?: string
          net_amount?: number
          payment_type?: string
          sale_date?: string
          updated_at?: string
          user_id: string
          vat_amount?: number
          vat_rate?: number
        }
        Update: {
          created_at?: string
          description?: string
          document_no?: string
          gross_amount?: number
          id?: string
          net_amount?: number
          payment_type?: string
          sale_date?: string
          updated_at?: string
          user_id?: string
          vat_amount?: number
          vat_rate?: number
        }
        Relationships: []
      }
      products: {
        Row: {
          created_at: string
          id: string
          name: string
          unit: string
          unit_price: number
          updated_at: string
          user_id: string
          vat_rate: number
        }
        Insert: {
          created_at?: string
          id?: string
          name: string
          unit?: string
          unit_price?: number
          updated_at?: string
          user_id: string
          vat_rate?: number
        }
        Update: {
          created_at?: string
          id?: string
          name?: string
          unit?: string
          unit_price?: number
          updated_at?: string
          user_id?: string
          vat_rate?: number
        }
        Relationships: []
      }
      profiles: {
        Row: {
          address: string
          company_title: string
          created_at: string
          email: string
          id: string
          phone: string
          tax_office: string
          updated_at: string
          vkn_tckn: string
        }
        Insert: {
          address?: string
          company_title?: string
          created_at?: string
          email?: string
          id: string
          phone?: string
          tax_office?: string
          updated_at?: string
          vkn_tckn?: string
        }
        Update: {
          address?: string
          company_title?: string
          created_at?: string
          email?: string
          id?: string
          phone?: string
          tax_office?: string
          updated_at?: string
          vkn_tckn?: string
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      [_ in never]: never
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
